import Foundation
import MeshCore

/// Deterministic in-memory mesh of `MeshNode`s with virtual time.
///
/// Links have their own MTU, latency and loss rate, can be cut and restored, and frames are
/// delivered in order per direction. Used by the test suite to exercise multi-hop routing,
/// store-and-forward, retries and encryption without radios, and by the app's demo mode.
public final class SimulatedMesh {
    public struct LinkProfile: Sendable {
        public var mtu: Int
        public var latency: TimeInterval
        public var lossRate: Double

        public init(mtu: Int = 182, latency: TimeInterval = 0.02, lossRate: Double = 0) {
            self.mtu = mtu
            self.latency = latency
            self.lossRate = lossRate
        }
    }

    private struct Edge: Hashable {
        let a: String
        let b: String
        init(_ x: String, _ y: String) { (a, b) = x < y ? (x, y) : (y, x) }
    }

    private struct Event {
        let time: Date
        let seq: Int
        let action: () -> Void
    }

    public private(set) var now: Date
    public private(set) var nodes: [String: MeshNode] = [:]
    public private(set) var recorders: [String: MeshRecorder] = [:]
    private var transports: [String: SimTransport] = [:]
    private var edges: [Edge: LinkProfile] = [:]
    private var events: [Event] = []
    private var seq = 0
    private var rng: SplitMix64
    private var lastTick: Date
    /// Per-direction "next free" time, so frames on one link arrive in order.
    private var linkBusyUntil: [String: Date] = [:]
    public private(set) var framesDelivered = 0
    public private(set) var framesDropped = 0

    public init(seed: UInt64 = 42, start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = start
        self.lastTick = start
        self.rng = SplitMix64(seed: seed)
    }

    // MARK: - Topology

    @discardableResult
    public func addNode(_ name: String, capabilities: PeerCapabilities = [], config: MeshConfig = MeshConfig(),
                        identity: MeshIdentity = MeshIdentity()) -> MeshNode {
        let node = MeshNode(identity: identity, nickname: name, capabilities: capabilities, config: config,
                            clock: { [unowned self] in self.now })
        let transport = SimTransport(name: name, mesh: self)
        let recorder = MeshRecorder()
        node.transport = transport
        node.delegate = recorder
        nodes[name] = node
        transports[name] = transport
        recorders[name] = recorder
        return node
    }

    /// Attach an externally created node (e.g. the app's real node in demo mode). The caller
    /// keeps its own delegate; the node's clock should track `now`.
    public func adopt(_ node: MeshNode, as name: String) {
        let transport = SimTransport(name: name, mesh: self)
        node.transport = transport
        nodes[name] = node
        transports[name] = transport
    }

    public func node(_ name: String) -> MeshNode { nodes[name]! }
    public func recorder(_ name: String) -> MeshRecorder { recorders[name]! }

    public func connect(_ a: String, _ b: String, profile: LinkProfile = LinkProfile()) {
        let edge = Edge(a, b)
        guard edges[edge] == nil else { return }
        edges[edge] = profile
        nodes[a]?.linkDidConnect(Self.linkID(from: a, to: b))
        nodes[b]?.linkDidConnect(Self.linkID(from: b, to: a))
    }

    public func disconnect(_ a: String, _ b: String) {
        guard edges.removeValue(forKey: Edge(a, b)) != nil else { return }
        nodes[a]?.linkDidDisconnect(Self.linkID(from: a, to: b))
        nodes[b]?.linkDidDisconnect(Self.linkID(from: b, to: a))
    }

    /// Connect nodes in a line: n0 - n1 - n2 ...
    public func chain(_ names: [String], profile: LinkProfile = LinkProfile()) {
        for (a, b) in zip(names, names.dropFirst()) { connect(a, b, profile: profile) }
    }

    public func isConnected(_ a: String, _ b: String) -> Bool { edges[Edge(a, b)] != nil }

    static func linkID(from a: String, to b: String) -> LinkID { LinkID("\(a)->\(b)") }

    // MARK: - Time

    /// Advance virtual time, delivering frames and ticking every node once per second.
    public func run(for duration: TimeInterval) {
        let end = now.addingTimeInterval(duration)
        while true {
            let nextTick = lastTick.addingTimeInterval(1)
            let nextEvent = events.first?.time
            let candidate = [nextTick, nextEvent].compactMap { $0 }.min()!
            guard candidate <= end else { break }
            now = candidate
            if let first = events.first, first.time <= now {
                events.removeFirst()
                first.action()
            } else {
                lastTick = nextTick
                for name in nodes.keys.sorted() { nodes[name]?.tick() }
            }
        }
        now = end
    }

    /// Run until `condition` holds or `timeout` elapses. Returns whether it held.
    @discardableResult
    public func run(until condition: () -> Bool, timeout: TimeInterval, step: TimeInterval = 0.25) -> Bool {
        var elapsed: TimeInterval = 0
        while elapsed < timeout {
            if condition() { return true }
            run(for: step)
            elapsed += step
        }
        return condition()
    }

    // MARK: - Delivery

    fileprivate func transmit(frames: [Data], from sender: String, over link: LinkID) -> Bool {
        guard let receiver = receiverName(sender: sender, link: link),
              let profile = edges[Edge(sender, receiver)] else { return false }
        let direction = link.raw
        var start = max(now, linkBusyUntil[direction] ?? now)
        for frame in frames {
            guard frame.count <= profile.mtu else {
                framesDropped += 1
                continue
            }
            // ~1 Mbit/s effective radio throughput plus base latency.
            let airtime = Double(frame.count * 8) / 1_000_000
            start = start.addingTimeInterval(airtime)
            if profile.lossRate > 0, Double(rng.next() % 10_000) / 10_000 < profile.lossRate {
                framesDropped += 1
                continue
            }
            let deliverAt = start.addingTimeInterval(profile.latency)
            let reverse = Self.linkID(from: receiver, to: sender)
            schedule(at: deliverAt) { [weak self] in
                guard let self, self.isConnected(sender, receiver) else { return }
                self.framesDelivered += 1
                self.nodes[receiver]?.receive(frame: frame, from: reverse)
            }
        }
        linkBusyUntil[direction] = start
        return true
    }

    fileprivate func mtu(sender: String, link: LinkID) -> Int {
        guard let receiver = receiverName(sender: sender, link: link) else { return 182 }
        return edges[Edge(sender, receiver)]?.mtu ?? 182
    }

    private func receiverName(sender: String, link: LinkID) -> String? {
        let prefix = "\(sender)->"
        guard link.raw.hasPrefix(prefix) else { return nil }
        return String(link.raw.dropFirst(prefix.count))
    }

    private func schedule(at time: Date, _ action: @escaping () -> Void) {
        seq += 1
        let event = Event(time: time, seq: seq, action: action)
        let index = events.firstIndex { ($0.time, $0.seq) > (time, event.seq) } ?? events.endIndex
        events.insert(event, at: index)
    }
}

/// Transport adapter that routes frames through the simulated network.
final class SimTransport: MeshTransport {
    let name: String
    unowned let mesh: SimulatedMesh

    init(name: String, mesh: SimulatedMesh) {
        self.name = name
        self.mesh = mesh
    }

    func send(frames: [Data], over link: LinkID) -> Bool {
        mesh.transmit(frames: frames, from: name, over: link)
    }

    func maximumFrameSize(for link: LinkID) -> Int {
        mesh.mtu(sender: name, link: link)
    }
}

/// Records everything a node reports, for assertions and demo UIs.
public final class MeshRecorder: MeshNodeDelegate {
    public private(set) var received: [ReceivedMessage] = []
    public private(set) var deliveryUpdates: [(UUID, DeliveryStatus)] = []
    public var onReceive: ((ReceivedMessage) -> Void)?
    public var onDelivery: ((UUID, DeliveryStatus) -> Void)?
    public var onPeersChanged: (() -> Void)?

    public init() {}

    public func meshNode(_ node: MeshNode, didReceive message: ReceivedMessage) {
        received.append(message)
        onReceive?(message)
    }

    public func meshNode(_ node: MeshNode, didUpdateDelivery messageID: UUID, status: DeliveryStatus) {
        deliveryUpdates.append((messageID, status))
        onDelivery?(messageID, status)
    }

    public func meshNodeDidUpdatePeers(_ node: MeshNode) {
        onPeersChanged?()
    }

    public func latestStatus(_ messageID: UUID) -> DeliveryStatus? {
        deliveryUpdates.last { $0.0 == messageID }?.1
    }

    public func texts() -> [String] {
        received.compactMap {
            if case .text(let t) = $0.envelope.content { return t }
            return nil
        }
    }
}

/// Small deterministic PRNG.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

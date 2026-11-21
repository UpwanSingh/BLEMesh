import Foundation
import MeshCore

/// Deterministic in-memory mesh of `MeshNode`s with virtual time.
///
/// Radio model: each node has **one shared radio** (like a phone's BLE radio) that transmits one
/// frame at a time at `radioBitrate`, from a priority queue across all of its links. Queues are
/// bounded; when full, the lowest-priority frames are dropped first. Links add latency and loss.
/// This is what makes congestion in crowds measurable. Nodes are polled every `pollInterval`
/// (for sub-second timers such as relay jitter) and ticked once per second.
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

    public struct RadioProfile: Sendable {
        /// Effective application throughput of one phone's radio (shared by all its links).
        public var bitrate: Double
        /// Fixed per-frame overhead (connection-event scheduling, headers).
        public var perFrameOverhead: TimeInterval
        /// Bounded transmit queue (frames). Lowest priority is dropped first when full.
        public var queueCapacity: Int

        public init(bitrate: Double = 1_000_000, perFrameOverhead: TimeInterval = 0, queueCapacity: Int = 100_000) {
            self.bitrate = bitrate
            self.perFrameOverhead = perFrameOverhead
            self.queueCapacity = queueCapacity
        }

        /// A realistic phone BLE radio: ~120 kbit/s effective, 1.5 ms per frame, 600-frame queue.
        public static let phone = RadioProfile(bitrate: 120_000, perFrameOverhead: 0.0015, queueCapacity: 600)
    }

    /// Per-run counters for measuring protocol efficiency.
    public struct Metrics: Sendable {
        public var framesTransmitted = 0
        public var bytesTransmitted = 0
        public var framesDelivered = 0
        public var framesLost = 0
        public var framesDroppedQueueFull = 0
        public var framesOversize = 0
        public var framesByPriority: [TrafficPriority: Int] = [:]
    }

    private struct Edge: Hashable {
        let a: String
        let b: String
        init(_ x: String, _ y: String) { (a, b) = x < y ? (x, y) : (y, x) }
    }

    private struct QueuedFrame {
        let priority: TrafficPriority
        let seq: Int
        let frame: Data
        let link: LinkID
    }

    public private(set) var now: Date
    public private(set) var nodes: [String: MeshNode] = [:]
    public private(set) var recorders: [String: MeshRecorder] = [:]
    public private(set) var positions: [String: (x: Double, y: Double)] = [:]
    public private(set) var metrics = Metrics()
    public var radio: RadioProfile
    public var pollInterval: TimeInterval = 0.05
    private var transports: [String: SimTransport] = [:]
    private var edges: [Edge: LinkProfile] = [:]
    private var events = EventQueue()
    private var rng: SplitMix64
    private var lastTick: Date
    private var lastPoll: Date
    private var radioQueues: [String: [QueuedFrame]] = [:]
    private var radioBusy: Set<String> = []
    private var frameSeq = 0
    /// Shared signature cache: every node still verifies, but identical bytes are only checked once.
    private var verified: [Data: Bool] = [:]

    public var framesDelivered: Int { metrics.framesDelivered }
    public var framesDropped: Int { metrics.framesLost + metrics.framesDroppedQueueFull + metrics.framesOversize }

    public init(seed: UInt64 = 42, start: Date = Date(timeIntervalSince1970: 1_800_000_000), radio: RadioProfile = RadioProfile()) {
        self.now = start
        self.lastTick = start
        self.lastPoll = start
        self.rng = SplitMix64(seed: seed)
        self.radio = radio
    }

    // MARK: - Topology

    @discardableResult
    public func addNode(_ name: String, capabilities: PeerCapabilities = [], config: MeshConfig = MeshConfig(),
                        identity: MeshIdentity = MeshIdentity()) -> MeshNode {
        let node = MeshNode(identity: identity, nickname: name, capabilities: capabilities, config: config,
                            clock: { [weak self] in self?.now ?? Date() })
        let recorder = MeshRecorder()
        node.delegate = recorder
        recorders[name] = recorder
        attach(node, as: name)
        return node
    }

    /// Attach an externally created node (e.g. the app's real node in demo mode). The caller
    /// keeps its own delegate; the node's clock should track `now`.
    public func adopt(_ node: MeshNode, as name: String) {
        attach(node, as: name)
    }

    private func attach(_ node: MeshNode, as name: String) {
        let transport = SimTransport(name: name, mesh: self)
        node.transport = transport
        node.packetVerifier = { [weak self] packet in self?.cachedVerify(packet) ?? packet.verify() }
        node.randomUnit = { [weak self] in self?.nextUnit() ?? 0.5 }
        nodes[name] = node
        transports[name] = transport
        radioQueues[name] = []
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

    public func neighbors(of name: String) -> [String] {
        edges.keys.compactMap { $0.a == name ? $0.b : ($0.b == name ? $0.a : nil) }
    }

    /// Place `count` nodes uniformly in a `width`×`height` metre area and link every pair within
    /// `range` metres, keeping at most `maxLinks` (nearest first) per node like a real BLE stack.
    /// Returns node names "n0"…"n{count-1}". The graph is made connected by linking stragglers
    /// to their nearest reachable node.
    @discardableResult
    public func scatter(count: Int, width: Double, height: Double, range: Double, maxLinks: Int = 8,
                        config: MeshConfig = MeshConfig(), profile: LinkProfile = LinkProfile(),
                        capabilities: (Int) -> PeerCapabilities = { _ in [] }) -> [String] {
        var names: [String] = []
        for i in 0..<count {
            let name = "n\(i)"
            names.append(name)
            positions[name] = (Double(rng.next() % 1_000_000) / 1_000_000 * width,
                               Double(rng.next() % 1_000_000) / 1_000_000 * height)
            addNode(name, capabilities: capabilities(i), config: config)
        }
        func distance(_ a: String, _ b: String) -> Double {
            let p = positions[a]!, q = positions[b]!
            return ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot()
        }
        var degree: [String: Int] = [:]
        var candidates: [(Double, String, String)] = []
        for (i, a) in names.enumerated() {
            for b in names[(i + 1)...] {
                let d = distance(a, b)
                if d <= range { candidates.append((d, a, b)) }
            }
        }
        for (_, a, b) in candidates.sorted(by: { $0.0 < $1.0 })
        where degree[a, default: 0] < maxLinks && degree[b, default: 0] < maxLinks {
            connect(a, b, profile: profile)
            degree[a, default: 0] += 1
            degree[b, default: 0] += 1
        }
        // Ensure one connected component (a crowd is contiguous; isolated phones aren't interesting here).
        var component = reachable(from: names[0])
        for name in names where !component.contains(name) {
            let nearest = component.min { distance(name, $0) < distance(name, $1) }!
            connect(name, nearest, profile: profile)
            component.formUnion(reachable(from: name))
        }
        return names
    }

    /// Hop distance between two nodes in the physical graph (BFS).
    public func hopDistance(_ a: String, _ b: String) -> Int? {
        var frontier = [a], seen: Set<String> = [a], hops = 0
        while !frontier.isEmpty {
            if frontier.contains(b) { return hops }
            hops += 1
            frontier = frontier.flatMap(neighbors(of:)).filter { seen.insert($0).inserted }
        }
        return nil
    }

    private func reachable(from start: String) -> Set<String> {
        var seen: Set<String> = [start], stack = [start]
        while let n = stack.popLast() {
            for m in neighbors(of: n) where seen.insert(m).inserted { stack.append(m) }
        }
        return seen
    }

    static func linkID(from a: String, to b: String) -> LinkID { LinkID("\(a)->\(b)") }

    public func resetMetrics() { metrics = Metrics() }

    // MARK: - Time

    /// Advance virtual time, delivering frames, polling nodes every `pollInterval` and ticking them once per second.
    public func run(for duration: TimeInterval) {
        let end = now.addingTimeInterval(duration)
        let order = nodes.keys.sorted()
        while true {
            let nextTick = lastTick.addingTimeInterval(1)
            let nextPoll = lastPoll.addingTimeInterval(pollInterval)
            let nextEvent = events.peekTime
            var candidate = min(nextTick, nextPoll)
            if let nextEvent { candidate = min(candidate, nextEvent) }
            guard candidate <= end else { break }
            now = candidate
            if let nextEvent, nextEvent <= now, let event = events.pop() {
                event()
            } else if nextPoll <= nextTick {
                lastPoll = nextPoll
                for name in order { nodes[name]?.poll() }
            } else {
                lastTick = nextTick
                for name in order { nodes[name]?.tick() }
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

    // MARK: - Radio

    fileprivate func transmit(frames: [Data], from sender: String, over link: LinkID, priority: TrafficPriority) -> Bool {
        guard let receiver = receiverName(sender: sender, link: link), edges[Edge(sender, receiver)] != nil else { return false }
        var queue = radioQueues[sender] ?? []
        for frame in frames {
            frameSeq += 1
            queue.append(QueuedFrame(priority: priority, seq: frameSeq, frame: frame, link: link))
        }
        // Bounded queue: shed the lowest-priority, newest frames first.
        if queue.count > radio.queueCapacity {
            queue.sort { ($0.priority, $0.seq) < ($1.priority, $1.seq) }
            let overflow = queue.count - radio.queueCapacity
            metrics.framesDroppedQueueFull += overflow
            queue.removeLast(overflow)
        }
        radioQueues[sender] = queue
        if !radioBusy.contains(sender) {
            radioBusy.insert(sender)
            events.push(at: now) { [weak self] in self?.transmitNext(sender) }
        }
        return true
    }

    private func transmitNext(_ sender: String) {
        guard var queue = radioQueues[sender], !queue.isEmpty else {
            radioBusy.remove(sender)
            return
        }
        // Highest priority first, FIFO within a priority (keeps fragments of one packet in order).
        var bestIndex = 0
        for i in 1..<queue.count where (queue[i].priority, queue[i].seq) < (queue[bestIndex].priority, queue[bestIndex].seq) {
            bestIndex = i
        }
        let item = queue.remove(at: bestIndex)
        radioQueues[sender] = queue

        let airtime = Double(item.frame.count * 8) / radio.bitrate + radio.perFrameOverhead
        defer { events.push(at: now.addingTimeInterval(airtime)) { [weak self] in self?.transmitNext(sender) } }

        guard let receiver = receiverName(sender: sender, link: item.link),
              let profile = edges[Edge(sender, receiver)] else { return } // link vanished while queued
        metrics.framesTransmitted += 1
        metrics.bytesTransmitted += item.frame.count
        metrics.framesByPriority[item.priority, default: 0] += 1
        guard item.frame.count <= profile.mtu else {
            metrics.framesOversize += 1
            return
        }
        if profile.lossRate > 0, Double(rng.next() % 10_000) / 10_000 < profile.lossRate {
            metrics.framesLost += 1
            return
        }
        let reverse = Self.linkID(from: receiver, to: sender)
        let frame = item.frame
        events.push(at: now.addingTimeInterval(airtime + profile.latency)) { [weak self] in
            guard let self, self.isConnected(sender, receiver) else { return }
            self.metrics.framesDelivered += 1
            self.nodes[receiver]?.receive(frame: frame, from: reverse)
        }
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

    fileprivate func nextUnit() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }

    private func cachedVerify(_ packet: Packet) -> Bool {
        let key = packet.signature + packet.originSigningKey
        if let known = verified[key] { return known }
        let result = packet.verify()
        if verified.count > 200_000 { verified.removeAll(keepingCapacity: true) }
        verified[key] = result
        return result
    }
}

/// Binary min-heap of timed events (stable for equal times).
private struct EventQueue {
    private struct Entry {
        let time: Date
        let seq: Int
        let action: () -> Void
        func precedes(_ other: Entry) -> Bool { (time, seq) < (other.time, other.seq) }
    }

    private var heap: [Entry] = []
    private var seq = 0

    var peekTime: Date? { heap.first?.time }

    mutating func push(at time: Date, _ action: @escaping () -> Void) {
        seq += 1
        heap.append(Entry(time: time, seq: seq, action: action))
        var i = heap.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard heap[i].precedes(heap[parent]) else { break }
            heap.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (() -> Void)? {
        guard !heap.isEmpty else { return nil }
        let top = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var smallest = i
                if l < heap.count, heap[l].precedes(heap[smallest]) { smallest = l }
                if r < heap.count, heap[r].precedes(heap[smallest]) { smallest = r }
                guard smallest != i else { break }
                heap.swapAt(i, smallest)
                i = smallest
            }
        }
        return top.action
    }
}

/// Transport adapter that routes frames through the simulated network.
final class SimTransport: MeshTransport {
    let name: String
    weak var mesh: SimulatedMesh?

    init(name: String, mesh: SimulatedMesh) {
        self.name = name
        self.mesh = mesh
    }

    func send(frames: [Data], over link: LinkID, priority: TrafficPriority) -> Bool {
        mesh?.transmit(frames: frames, from: name, over: link, priority: priority) ?? false
    }

    func maximumFrameSize(for link: LinkID) -> Int {
        mesh?.mtu(sender: name, link: link) ?? 182
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

    public func hasReceived(_ messageID: UUID) -> Bool {
        received.contains { $0.envelope.messageID == messageID }
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

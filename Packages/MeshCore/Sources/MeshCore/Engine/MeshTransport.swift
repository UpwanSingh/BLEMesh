import Foundation

/// Scheduling class for outbound traffic. When a radio is congested, transports send higher
/// priorities first and drop the lowest priorities first.
public enum TrafficPriority: Int, Comparable, Sendable, CaseIterable {
    /// Link control and end-to-end acks — tiny, and everything else depends on them.
    case control = 0
    /// SOS and other urgent traffic.
    case urgent = 1
    /// Direct and group messages.
    case direct = 2
    /// Public channel chat.
    case normal = 3
    /// Presence announces and store-and-forward hand-offs.
    case background = 4

    public static func < (lhs: TrafficPriority, rhs: TrafficPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A link-layer transport (BLE, Wi-Fi Aware, simulator...).
///
/// The transport owns flow control: `send` must queue frames and deliver them in order,
/// retrying when the underlying radio reports back-pressure. It reports link lifecycle and
/// inbound frames back to the node via `MeshNode.linkDidConnect`, `linkDidDisconnect`
/// and `receive(frame:from:)`.
public protocol MeshTransport: AnyObject {
    /// Queue frames for in-order delivery over `link`. Returns false if the link is gone.
    /// Frames of one call must stay in order; transports may reorder across priorities.
    @discardableResult
    func send(frames: [Data], over link: LinkID, priority: TrafficPriority) -> Bool

    /// Largest frame the link can carry in one write/notification.
    func maximumFrameSize(for link: LinkID) -> Int
}

/// Events the node reports to the application.
public protocol MeshNodeDelegate: AnyObject {
    func meshNode(_ node: MeshNode, didReceive message: ReceivedMessage)
    func meshNode(_ node: MeshNode, didUpdateDelivery messageID: UUID, status: DeliveryStatus)
    func meshNodeDidUpdatePeers(_ node: MeshNode)
}

public extension MeshNodeDelegate {
    func meshNode(_ node: MeshNode, didUpdateDelivery messageID: UUID, status: DeliveryStatus) {}
    func meshNodeDidUpdatePeers(_ node: MeshNode) {}
}

/// Where an inbound message was addressed.
public enum MessageScope: Equatable, Sendable {
    /// Public, signed, unencrypted channel everyone nearby can read.
    case broadcast
    /// End-to-end encrypted to this device.
    case direct
    /// Encrypted with a group key this device holds.
    case group(UUID)
}

public struct ReceivedMessage: Equatable, Sendable {
    public let envelope: MessageEnvelope
    public let sender: PeerID
    public let scope: MessageScope
    public let hops: Int
    public let receivedAt: Date
}

public enum DeliveryStatus: Int, Codable, Sendable, Comparable {
    /// Waiting for the recipient's keys or for any link to exist.
    case queued = 0
    /// Transmitted at least once, no acknowledgement yet.
    case sent = 1
    case delivered = 2
    case read = 3
    case failed = 4

    public static func < (lhs: DeliveryStatus, rhs: DeliveryStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

import Foundation
import WatchConnectivity
import WatchKit

/// Talks to the iPhone app, which sends SOS calls and check-ins over the Bluetooth mesh.
@MainActor
final class WatchModel: NSObject, ObservableObject {
    enum Delivery: Equatable {
        case idle
        case sending
        /// The iPhone confirmed it went out over the mesh.
        case sent
        /// The iPhone isn't reachable; WatchConnectivity will deliver it when it is.
        case queued
        case noGroups
        case failed
    }

    @Published private(set) var sosDelivery: Delivery = .idle
    @Published private(set) var safeDelivery: Delivery = .idle
    @Published private(set) var peers: Int?
    @Published private(set) var sosStatus: String?
    @Published private(set) var sosResponders = 0
    @Published private(set) var phoneReachable = false

    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func sendSOS() {
        WKInterfaceDevice.current().play(.notification)
        send(.sos, update: { self.sosDelivery = $0 })
    }

    func sendSafe() {
        WKInterfaceDevice.current().play(.success)
        send(.safe, update: { self.safeDelivery = $0 })
    }

    private func send(_ action: WatchMessage.Action, update: @escaping (Delivery) -> Void) {
        let request = WatchMessage.request(action)
        update(.sending)
        guard let session, session.activationState == .activated else {
            update(.failed)
            return
        }
        guard session.isReachable else {
            // Queued: delivered in order when the iPhone app can be reached (also after relaunch).
            session.transferUserInfo(request)
            update(.queued)
            return
        }
        session.sendMessage(request, replyHandler: { reply in
            let status = WatchStatus(reply)
            Task { @MainActor in
                self.apply(status)
                update(status.result == WatchMessage.Result.noGroups.rawValue ? .noGroups
                       : status.result == WatchMessage.Result.sent.rawValue ? .sent : .failed)
            }
        }, errorHandler: { _ in
            session.transferUserInfo(request)
            Task { @MainActor in update(.queued) }
        })
    }

    fileprivate func apply(_ status: WatchStatus) {
        if let peers = status.peers { self.peers = peers }
        sosStatus = status.sosStatus
        sosResponders = status.sosResponders ?? 0
    }
}

/// Plist dictionary values copied out of a WatchConnectivity callback.
struct WatchStatus: Sendable {
    var result: String?
    var peers: Int?
    var sosStatus: String?
    var sosResponders: Int?

    init(_ dictionary: [String: Any]) {
        result = dictionary[WatchMessage.Key.result] as? String
        peers = dictionary[WatchMessage.Key.peers] as? Int
        sosStatus = dictionary[WatchMessage.Key.sosStatus] as? String
        sosResponders = dictionary[WatchMessage.Key.sosResponders] as? Int
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let status = WatchStatus(session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachable = reachable
            self.apply(status)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.phoneReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let status = WatchStatus(context)
        Task { @MainActor in self.apply(status) }
    }
}

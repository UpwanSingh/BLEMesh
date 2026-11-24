import Combine
import Foundation
import WatchConnectivity
import MeshCore

/// Receives SOS / check-in requests from the Watch app and sends them over the mesh, and keeps the
/// watch up to date (people in reach, status of your latest SOS).
@MainActor
final class WatchBridge: NSObject {
    private weak var mesh: MeshService?
    private let session: WCSession?
    private var updates: AnyCancellable?

    init(mesh: MeshService, session: WCSession? = WCSession.isSupported() ? .default : nil) {
        self.mesh = mesh
        self.session = session
        super.init()
        session?.delegate = self
        session?.activate()
        // Keep the watch's status fresh without flooding it.
        updates = mesh.objectWillChange
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.pushStatus() }
    }

    /// Handle one request from the watch; returns the reply dictionary.
    func handle(_ message: [String: Any], now: Date = Date()) async -> [String: Any] {
        guard let mesh, let raw = message[WatchMessage.Key.action] as? String,
              let action = WatchMessage.Action(rawValue: raw) else {
            return [WatchMessage.Key.result: WatchMessage.Result.failed.rawValue]
        }
        if let requestedAt = message[WatchMessage.Key.requestedAt] as? Double,
           now.timeIntervalSince1970 - requestedAt > WatchMessage.maxRequestAge, action != .status {
            return status(mesh, result: .failed)
        }
        switch action {
        case .sos:
            let text = (message[WatchMessage.Key.text] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "SOS from my Apple Watch — I need help")
            await mesh.refreshMyLocation()
            _ = await mesh.sendSOS(text: text, location: mesh.myLocation)
            return status(mesh, result: .sent)
        case .safe:
            let groups = mesh.sendCheckIn(.safe)
            return status(mesh, result: groups > 0 ? .sent : .noGroups)
        case .status:
            return status(mesh, result: .sent)
        }
    }

    /// Current status for the watch: people in reach and the state of your latest open SOS.
    func status(_ mesh: MeshService, result: WatchMessage.Result) -> [String: Any] {
        var reply: [String: Any] = [WatchMessage.Key.result: result.rawValue,
                                    WatchMessage.Key.peers: mesh.peers.filter(\.isReachable).count]
        if let (message, state) = mesh.latestOwnSOS() {
            reply[WatchMessage.Key.sosStatus] = L(state.status.label)
            reply[WatchMessage.Key.sosResponders] = state.responders.count
            reply[WatchMessage.Key.sosSentAt] = message.sentAt.timeIntervalSince1970
        }
        return reply
    }

    /// Push the latest status to the watch (cheap; the system coalesces updates).
    func pushStatus() {
        guard let mesh, let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(status(mesh, result: .sent))
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushStatus() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let request = WatchRequest(message)
        Task { @MainActor in replyHandler(await self.handle(request.message)) }
    }

    /// Queued requests (sent while the iPhone wasn't reachable).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let request = WatchRequest(userInfo)
        Task { @MainActor in
            _ = await self.handle(request.message)
            self.pushStatus()
        }
    }
}

/// WatchConnectivity dictionaries hold only property-list values; wrap one to cross actors.
private struct WatchRequest: @unchecked Sendable {
    let message: [String: Any]
    init(_ message: [String: Any]) { self.message = message }
}

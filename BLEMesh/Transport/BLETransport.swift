import Foundation
import CoreBluetooth
import MeshCore

/// CoreBluetooth transport: every device is both central (scans + connects) and peripheral
/// (advertises one characteristic), and each GATT connection is one mesh link.
///
/// Everything runs on the main queue — the same queue as `MeshNode` — so there is no shared
/// mutable state across threads. Outbound frames are queued per link and only written when
/// CoreBluetooth reports capacity (`canSendWriteWithoutResponse` / `updateValue` returning true),
/// so nothing is silently dropped under load.
@MainActor
final class BLETransport: NSObject, MeshTransport {
    enum Constants {
        static let serviceUUID = CBUUID(string: "6E2A0001-7B3C-4E8B-9A51-2F6C4D1B8E10")
        static let frameCharacteristicUUID = CBUUID(string: "6E2A0002-7B3C-4E8B-9A51-2F6C4D1B8E10")
        static let centralRestoreID = "mesh.central"
        static let peripheralRestoreID = "mesh.peripheral"
        static let maxLinks = 8
        static let minimumRSSI = -92
        static let connectTimeout: TimeInterval = 10
        static let rescanInterval: TimeInterval = 30
        static let maintenanceInterval: TimeInterval = 2
        /// Never exceed this even if the stack negotiates more; keeps fragments small enough
        /// to interleave fairly between links.
        static let maxFrameCap = 512
    }

    weak var node: MeshNode?
    /// Called on any state change the UI may care about (power state, link count).
    var onStateChange: (() -> Void)?

    private(set) var centralState: CBManagerState = .unknown
    private(set) var peripheralState: CBManagerState = .unknown
    var isPoweredOn: Bool { centralState == .poweredOn && peripheralState == .poweredOn }
    /// Links that are fully up (connecting/discovering centrals don't count).
    var linkCount: Int { centralLinks.values.filter(\.isUp).count + peripheralLinks.count }

    private var central: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var frameCharacteristic: CBMutableCharacteristic?
    private var serviceAdded = false

    /// Links where we are the central (we connected to them).
    private struct CentralLink {
        let peripheral: CBPeripheral
        var characteristic: CBCharacteristic?
        var queue = FrameQueue()
        var isUp = false
    }
    private var centralLinks: [UUID: CentralLink] = [:]
    /// Central links not yet up (connecting, discovering, subscribing) and when they started.
    /// Cleared only when the link is up, so setup is bounded by the connect timeout end to end.
    private var connecting: [UUID: Date] = [:]
    /// Peripherals handed back by state restoration, processed once the central is powered on.
    private var restoredPeripherals: [CBPeripheral] = []
    /// Short cool-down after a failed/closed connection, to avoid hammering a peer.
    private var backoffUntil: [UUID: Date] = [:]

    /// Links where we are the peripheral (they subscribed to us).
    private struct PeripheralLink {
        let central: CBCentral
        var queue = FrameQueue()
    }
    private var peripheralLinks: [UUID: PeripheralLink] = [:]
    /// Notifications are sent through one shared transmit queue; this tracks fairness.
    private var peripheralBlocked = false

    private var rescanTimer: Timer?
    private var maintenanceTimer: Timer?
    /// The local name we advertise: the first 8 hex chars of our PeerID. When both devices see
    /// each other, only the one with the smaller ID initiates, avoiding duplicate links.
    private let advertisedName: String

    init(localPeerID: PeerID) {
        self.advertisedName = "M" + localPeerID.short
        super.init()
    }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Constants.centralRestoreID,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main, options: [
            CBPeripheralManagerOptionRestoreIdentifierKey: Constants.peripheralRestoreID,
        ])
        rescanTimer = Timer.scheduledTimer(withTimeInterval: Constants.rescanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartScan() }
        }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: Constants.maintenanceInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.expireStaleConnects()
                self?.dropDuplicateLinks()
            }
        }
    }

    func stop() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        // Withdraw our GATT service so connected peers see it invalidated and drop the link.
        peripheralManager?.removeAllServices()
        for link in centralLinks.values { central?.cancelPeripheralConnection(link.peripheral) }
        for id in Array(centralLinks.keys) { tearDownCentralLink(id) }
        for id in Array(peripheralLinks.keys) { tearDownPeripheralLink(id) }
        central = nil
        peripheralManager = nil
        serviceAdded = false
    }

    // MARK: - MeshTransport

    nonisolated func send(frames: [Data], over link: LinkID, priority: TrafficPriority) -> Bool {
        MainActor.assumeIsolated { enqueue(frames: frames, over: link, priority: priority) }
    }

    nonisolated func maximumFrameSize(for link: LinkID) -> Int {
        MainActor.assumeIsolated { frameSize(for: link) }
    }

    private func enqueue(frames: [Data], over link: LinkID, priority: TrafficPriority) -> Bool {
        switch Self.parse(link) {
        case .central(let id)?:
            guard centralLinks[id]?.isUp == true else { return false }
            centralLinks[id]!.queue.append(frames, priority: priority)
            pumpCentral(id)
            return true
        case .peripheral(let id)?:
            guard peripheralLinks[id] != nil else { return false }
            peripheralLinks[id]!.queue.append(frames, priority: priority)
            pumpPeripheral()
            return true
        case nil:
            return false
        }
    }

    private func frameSize(for link: LinkID) -> Int {
        switch Self.parse(link) {
        case .central(let id)?:
            guard let peripheral = centralLinks[id]?.peripheral else { return 20 }
            return min(peripheral.maximumWriteValueLength(for: .withoutResponse), Constants.maxFrameCap)
        case .peripheral(let id)?:
            guard let central = peripheralLinks[id]?.central else { return 20 }
            return min(central.maximumUpdateValueLength, Constants.maxFrameCap)
        case nil:
            return 20
        }
    }

    // MARK: - Link IDs

    private enum LinkKind { case central(UUID), peripheral(UUID) }

    private static func linkID(central id: UUID) -> LinkID { LinkID("c:\(id.uuidString)") }
    private static func linkID(peripheral id: UUID) -> LinkID { LinkID("p:\(id.uuidString)") }

    private static func parse(_ link: LinkID) -> LinkKind? {
        let raw = link.raw
        guard raw.count > 2, let id = UUID(uuidString: String(raw.dropFirst(2))) else { return nil }
        if raw.hasPrefix("c:") { return .central(id) }
        if raw.hasPrefix("p:") { return .peripheral(id) }
        return nil
    }

    // MARK: - Pumps (flow control)

    private func pumpCentral(_ id: UUID) {
        guard var link = centralLinks[id], link.isUp, let characteristic = link.characteristic else { return }
        while !link.queue.isEmpty, link.peripheral.canSendWriteWithoutResponse {
            let frame = link.queue.removeFirst()
            link.peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
        }
        centralLinks[id] = link
    }

    private func pumpPeripheral() {
        guard let characteristic = frameCharacteristic, let manager = peripheralManager else { return }
        peripheralBlocked = false
        // Round-robin one frame per link per pass so one busy link can't starve the others.
        var progressed = true
        while progressed {
            progressed = false
            for id in Array(peripheralLinks.keys) {
                guard var link = peripheralLinks[id], let frame = link.queue.first else { continue }
                if manager.updateValue(frame, for: characteristic, onSubscribedCentrals: [link.central]) {
                    link.queue.removeFirst()
                    peripheralLinks[id] = link
                    progressed = true
                } else {
                    peripheralBlocked = true // resumes in peripheralManagerIsReady(toUpdateSubscribers:)
                    return
                }
            }
        }
    }

    // MARK: - Scanning / advertising

    private func startScanningIfPossible() {
        guard central?.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Constants.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func restartScan() {
        guard central?.state == .poweredOn else { return }
        central.stopScan()
        expireStaleConnects()
        startScanningIfPossible()
    }

    private func startAdvertisingIfPossible() {
        guard let manager = peripheralManager, manager.state == .poweredOn else { return }
        if !serviceAdded {
            let characteristic = CBMutableCharacteristic(
                type: Constants.frameCharacteristicUUID,
                properties: [.writeWithoutResponse, .write, .notify],
                value: nil,
                permissions: [.writeable]
            )
            let service = CBMutableService(type: Constants.serviceUUID, primary: true)
            service.characteristics = [characteristic]
            manager.add(service)
            frameCharacteristic = characteristic
            serviceAdded = true
        }
        if !manager.isAdvertising {
            manager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [Constants.serviceUUID],
                CBAdvertisementDataLocalNameKey: advertisedName,
            ])
        }
    }

    private func expireStaleConnects() {
        guard let central else { return }
        let now = Date()
        for (id, started) in connecting where now.timeIntervalSince(started) > Constants.connectTimeout {
            connecting[id] = nil
            if let peripheral = centralLinks[id]?.peripheral { central.cancelPeripheralConnection(peripheral) }
            centralLinks[id] = nil
            backoffUntil[id] = now.addingTimeInterval(15)
        }
    }

    /// When both phones connected to each other (e.g. a backgrounded advertiser hides its name,
    /// defeating the tie-break), two links lead to the same proven neighbour. The phone with the
    /// larger mesh ID closes its central connection; the other keeps it — so exactly one survives.
    private func dropDuplicateLinks() {
        guard let node, let central else { return }
        var peripheralNeighbors: Set<PeerID> = []
        for id in peripheralLinks.keys {
            if let neighbor = node.provenNeighbor(on: Self.linkID(peripheral: id)) { peripheralNeighbors.insert(neighbor) }
        }
        for (id, link) in centralLinks where link.isUp {
            guard let neighbor = node.provenNeighbor(on: Self.linkID(central: id)),
                  peripheralNeighbors.contains(neighbor), node.peerID > neighbor else { continue }
            MeshLogger.connection.info("Closing duplicate link to \(neighbor.short, privacy: .public)")
            central.cancelPeripheralConnection(link.peripheral)
        }
    }

    /// Mark a central link up once we're subscribed to the peer's characteristic.
    private func centralLinkUp(_ id: UUID) {
        guard var link = centralLinks[id], !link.isUp else { return }
        link.isUp = true
        centralLinks[id] = link
        connecting[id] = nil
        MeshLogger.connection.info("Link up (central) \(id.uuidString, privacy: .public)")
        node?.linkDidConnect(Self.linkID(central: id))
        onStateChange?()
    }

    /// Re-adopt connections iOS kept alive while the app was suspended or terminated.
    private func adoptRestoredPeripherals() {
        let restored = restoredPeripherals
        restoredPeripherals = []
        let now = Date()
        for peripheral in restored {
            let id = peripheral.identifier
            switch peripheral.state {
            case .connected:
                var link = centralLinks[id] ?? CentralLink(peripheral: peripheral)
                let characteristic = peripheral.services?
                    .first { $0.uuid == Constants.serviceUUID }?
                    .characteristics?.first { $0.uuid == Constants.frameCharacteristicUUID }
                link.characteristic = characteristic
                centralLinks[id] = link
                if let characteristic, characteristic.isNotifying {
                    centralLinkUp(id) // already subscribed; no callback will come
                } else {
                    connecting[id] = now
                    peripheral.discoverServices([Constants.serviceUUID])
                }
            case .connecting:
                centralLinks[id] = CentralLink(peripheral: peripheral)
                connecting[id] = now
            default:
                central.cancelPeripheralConnection(peripheral)
                centralLinks[id] = nil
            }
        }
    }

    private func shouldConnect(to peripheral: CBPeripheral, advertisedName name: String?, rssi: Int) -> Bool {
        let id = peripheral.identifier
        guard centralLinks[id] == nil, connecting[id] == nil else { return false }
        guard rssi >= Constants.minimumRSSI, rssi != 127 else { return false }
        if let until = backoffUntil[id], until > Date() { return false }
        guard linkCount + connecting.count < Constants.maxLinks else { return false }
        // Tie-break so two phones don't both connect to each other.
        if let name, name.hasPrefix("M"), name.count == advertisedName.count {
            return advertisedName < name
        }
        return true
    }

    // MARK: - Teardown

    private func tearDownCentralLink(_ id: UUID) {
        connecting[id] = nil
        guard let link = centralLinks.removeValue(forKey: id) else { return }
        if link.isUp { node?.linkDidDisconnect(Self.linkID(central: id)) }
        onStateChange?()
    }

    private func tearDownPeripheralLink(_ id: UUID) {
        guard peripheralLinks.removeValue(forKey: id) != nil else { return }
        node?.linkDidDisconnect(Self.linkID(peripheral: id))
        onStateChange?()
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            centralState = central.state
            if central.state == .poweredOn {
                adoptRestoredPeripherals()
                startScanningIfPossible()
            } else {
                for id in Array(centralLinks.keys) { tearDownCentralLink(id) }
            }
            onStateChange?()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            // Commands are ignored until the manager is powered on, so adopt them then.
            let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            for peripheral in restored { peripheral.delegate = self }
            restoredPeripherals = restored
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            guard shouldConnect(to: peripheral, advertisedName: name, rssi: RSSI.intValue) else { return }
            connecting[peripheral.identifier] = Date()
            centralLinks[peripheral.identifier] = CentralLink(peripheral: peripheral)
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            MeshLogger.bluetooth.info("Connecting to \(name ?? peripheral.identifier.uuidString, privacy: .public) rssi \(RSSI.intValue)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            // `connecting` stays set until the link is up, so discovery/subscription is time-bounded.
            peripheral.discoverServices([Constants.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            backoffUntil[peripheral.identifier] = Date().addingTimeInterval(10)
            tearDownCentralLink(peripheral.identifier)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let minimum = Date().addingTimeInterval(3)
            backoffUntil[peripheral.identifier] = max(backoffUntil[peripheral.identifier] ?? minimum, minimum)
            tearDownCentralLink(peripheral.identifier)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Constants.serviceUUID }) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverCharacteristics([Constants.frameCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil,
                  let characteristic = service.characteristics?.first(where: { $0.uuid == Constants.frameCharacteristicUUID }) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            centralLinks[peripheral.identifier]?.characteristic = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, characteristic.isNotifying else {
                // Couldn't subscribe: give the slot back instead of holding a dead connection.
                central.cancelPeripheralConnection(peripheral)
                return
            }
            centralLinkUp(peripheral.identifier)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            // The peer withdrew our service (app stopped, panic wipe…) while the radio link stayed up.
            if invalidatedServices.contains(where: { $0.uuid == Constants.serviceUUID }) {
                central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let value = characteristic.value, centralLinks[peripheral.identifier]?.isUp == true else { return }
            node?.receive(frame: value, from: Self.linkID(central: peripheral.identifier))
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { pumpCentral(peripheral.identifier) }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLETransport: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            peripheralState = peripheral.state
            if peripheral.state == .poweredOn {
                startAdvertisingIfPossible()
            } else {
                serviceAdded = false
                for id in Array(peripheralLinks.keys) { tearDownPeripheralLink(id) }
            }
            onStateChange?()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
               let service = services.first(where: { $0.uuid == Constants.serviceUUID }),
               let characteristic = service.characteristics?.first(where: { $0.uuid == Constants.frameCharacteristicUUID }) as? CBMutableCharacteristic {
                frameCharacteristic = characteristic
                serviceAdded = true
                // Centrals still subscribed across the restore are live links already.
                for central in characteristic.subscribedCentrals ?? [] where peripheralLinks[central.identifier] == nil {
                    peripheralLinks[central.identifier] = PeripheralLink(central: central)
                    node?.linkDidConnect(Self.linkID(peripheral: central.identifier))
                }
                onStateChange?()
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Constants.frameCharacteristicUUID, peripheralLinks[central.identifier] == nil else { return }
            peripheralLinks[central.identifier] = PeripheralLink(central: central)
            MeshLogger.connection.info("Link up (peripheral) \(central.identifier.uuidString, privacy: .public)")
            node?.linkDidConnect(Self.linkID(peripheral: central.identifier))
            onStateChange?()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated { tearDownPeripheralLink(central.identifier) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated {
            for request in requests where request.characteristic.uuid == Constants.frameCharacteristicUUID {
                guard let value = request.value else { continue }
                let id = request.central.identifier
                if peripheralLinks[id] == nil {
                    // A central may write before subscribing; treat it as a link.
                    peripheralLinks[id] = PeripheralLink(central: request.central)
                    node?.linkDidConnect(Self.linkID(peripheral: id))
                    onStateChange?()
                }
                node?.receive(frame: value, from: Self.linkID(peripheral: id))
            }
            // Per CoreBluetooth contract: respond once, to the first request (ignored for
            // write-without-response, required for acknowledged writes).
            if let first = requests.first {
                peripheral.respond(to: first, withResult: .success)
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { pumpPeripheral() }
    }
}

/// Per-link outbound frames: FIFO within a priority, higher priorities first, bounded so a
/// congested link sheds announces and chatter before acks and SOS.
struct FrameQueue {
    static let capacity = 400
    private var lanes: [[Data]] = Array(repeating: [], count: TrafficPriority.allCases.count)
    private(set) var count = 0
    private(set) var dropped = 0

    var isEmpty: Bool { count == 0 }

    var first: Data? { lanes.first { !$0.isEmpty }?.first }

    mutating func append(_ frames: [Data], priority: TrafficPriority) {
        lanes[priority.rawValue].append(contentsOf: frames)
        count += frames.count
        // Shed from the lowest-priority lane, newest first.
        while count > Self.capacity, let lane = lanes.indices.last(where: { !lanes[$0].isEmpty }), lane > priority.rawValue || lanes[lane].count > frames.count {
            lanes[lane].removeLast()
            count -= 1
            dropped += 1
        }
    }

    @discardableResult
    mutating func removeFirst() -> Data {
        let lane = lanes.indices.first { !lanes[$0].isEmpty }!
        count -= 1
        return lanes[lane].removeFirst()
    }
}

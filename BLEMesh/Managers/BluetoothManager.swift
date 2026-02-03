import Foundation
import CoreBluetooth
import Combine
import UIKit

/// Dual-role Bluetooth manager handling both Central and Peripheral operations
final class BluetoothManager: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var centralState: CBManagerState = .unknown
    @Published private(set) var peripheralState: CBManagerState = .unknown
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var isAdvertising: Bool = false
    @Published private(set) var discoveredPeers: [UUID: Peer] = [:]
    @Published private(set) var connectedPeers: [UUID: Peer] = [:]
    
    /// Combined Bluetooth ready state
    var isBluetoothReady: Bool {
        centralState == .poweredOn && peripheralState == .poweredOn
    }
    
    // MARK: - Device Identity
    
    let localDeviceID: UUID
    let localDeviceName: String
    
    // MARK: - Callbacks
    
    var onMessageReceived: ((Data, Peer) -> Void)?
    var onPeerConnected: ((Peer) -> Void)?
    var onPeerDisconnected: ((Peer) -> Void)?
    
    // MARK: - Private Properties
    
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    
    private var messageCharacteristic: CBMutableCharacteristic?
    private var deviceIDCharacteristic: CBMutableCharacteristic?
    
    private var subscribedCentrals: Set<CBCentral> = []
    private var pendingConnections: Set<UUID> = []
    
    private let queue = DispatchQueue(label: "com.blemesh.bluetooth", qos: .userInitiated)
    private var reconnectTimers: [UUID: Timer] = [:]
    
    /// Lock for thread-safe access to shared state
    private let stateLock = NSLock()
    
    /// Thread-safe copy of connected peers for background access
    private var _connectedPeersSnapshot: [UUID: Peer] = [:]
    
    // MARK: - Initialization
    
    override init() {
        self.localDeviceID = UUID()
        self.localDeviceName = "\(BLEConstants.deviceNamePrefix)-\(UIDevice.current.name.prefix(10))"
        
        super.init()
        
        // Initialize managers on dedicated queue
        centralManager = CBCentralManager(delegate: self, queue: queue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: queue)
        
        MeshLogger.bluetooth.info("BluetoothManager initialized | DeviceID: \(self.localDeviceID)")
    }
    
    // MARK: - Public API
    
    /// Start scanning for nearby devices
    func startScanning() {
        guard centralState == .poweredOn else {
            MeshLogger.bluetooth.warning("Cannot scan - Central not powered on")
            return
        }
        
        guard !isScanning else { return }
        
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.meshServiceUUID],
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ]
        )
        
        DispatchQueue.main.async {
            self.isScanning = true
        }
        
        MeshLogger.bluetooth.info("Started scanning for mesh devices")
    }
    
    /// Stop scanning
    func stopScanning() {
        guard isScanning else { return }
        
        centralManager.stopScan()
        
        DispatchQueue.main.async {
            self.isScanning = false
        }
        
        MeshLogger.bluetooth.info("Stopped scanning")
    }
    
    /// Start advertising as peripheral
    func startAdvertising() {
        guard peripheralState == .poweredOn else {
            MeshLogger.bluetooth.warning("Cannot advertise - Peripheral not powered on")
            return
        }
        
        guard !isAdvertising else { return }
        
        setupPeripheralService()
        
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.meshServiceUUID],
            CBAdvertisementDataLocalNameKey: localDeviceName
        ])
        
        DispatchQueue.main.async {
            self.isAdvertising = true
        }
        
        MeshLogger.bluetooth.info("Started advertising as: \(self.localDeviceName)")
    }
    
    /// Stop advertising
    func stopAdvertising() {
        guard isAdvertising else { return }
        
        peripheralManager.stopAdvertising()
        
        DispatchQueue.main.async {
            self.isAdvertising = false
        }
        
        MeshLogger.bluetooth.info("Stopped advertising")
    }
    
    /// Connect to a discovered peer
    func connect(to peer: Peer) {
        guard let peripheral = peer.peripheral else {
            MeshLogger.bluetooth.error("Cannot connect - no peripheral for peer: \(peer.name)")
            return
        }
        
        guard !pendingConnections.contains(peer.id) else {
            MeshLogger.bluetooth.debug("Connection already pending for: \(peer.name)")
            return
        }
        
        pendingConnections.insert(peer.id)
        
        DispatchQueue.main.async {
            peer.updateState(.connecting)
        }
        
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        
        MeshLogger.connection.info("Connecting to: \(peer.name)")
        
        // Set connection timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEConstants.connectionTimeout) { [weak self] in
            guard let self = self,
                  self.pendingConnections.contains(peer.id),
                  peer.state == .connecting else { return }
            
            self.cancelConnection(to: peer)
            MeshLogger.connection.warning("Connection timeout for: \(peer.name)")
        }
    }
    
    /// Disconnect from a peer
    func disconnect(from peer: Peer) {
        if let peripheral = peer.peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        DispatchQueue.main.async {
            peer.updateState(.disconnected)
            self.connectedPeers.removeValue(forKey: peer.id)
            self.updatePeerSnapshot()
        }
        
        MeshLogger.connection.deviceDisconnected(name: peer.name, uuid: peer.id.uuidString)
    }
    
    /// Cancel pending connection
    func cancelConnection(to peer: Peer) {
        pendingConnections.remove(peer.id)
        
        if let peripheral = peer.peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        DispatchQueue.main.async {
            peer.updateState(.failed)
        }
    }
    
    /// Send data to a specific peer
    func send(data: Data, to peer: Peer) -> Bool {
        // Try sending via peripheral's characteristic (if we're central)
        if let peripheral = peer.peripheral,
           let characteristic = peer.messageCharacteristic {
            peripheral.writeValue(
                data,
                for: characteristic,
                type: .withResponse
            )
            MeshLogger.message.messageSent(
                id: "chunk",
                to: peer.name,
                size: data.count
            )
            return true
        }
        
        // Try sending via our characteristic (if they're subscribed central)
        if let central = peer.central,
           let characteristic = messageCharacteristic,
           subscribedCentrals.contains(central) {
            let success = peripheralManager.updateValue(
                data,
                for: characteristic,
                onSubscribedCentrals: [central]
            )
            if success {
                MeshLogger.message.messageSent(
                    id: "chunk",
                    to: peer.name,
                    size: data.count
                )
            }
            return success
        }
        
        MeshLogger.message.warning("Cannot send to peer: \(peer.name) - no valid channel")
        return false
    }
    
    /// Broadcast data to all connected peers (thread-safe)
    func broadcast(data: Data, excluding: Set<UUID> = []) -> Int {
        var successCount = 0
        
        // Get thread-safe snapshot of connected peers
        stateLock.lock()
        let peersSnapshot = _connectedPeersSnapshot
        stateLock.unlock()
        
        for (id, peer) in peersSnapshot where !excluding.contains(id) {
            if send(data: data, to: peer) {
                successCount += 1
            }
        }
        
        return successCount
    }
    
    /// Get all connected peers (thread-safe)
    func getAllConnectedPeers() -> [Peer] {
        stateLock.lock()
        let peers = Array(_connectedPeersSnapshot.values)
        stateLock.unlock()
        return peers
    }
    
    /// Thread-safe peer lookup by ID
    func getConnectedPeer(_ id: UUID) -> Peer? {
        stateLock.lock()
        let peer = _connectedPeersSnapshot[id]
        stateLock.unlock()
        return peer
    }
    
    /// Update the thread-safe peer snapshot (call on main thread when connectedPeers changes)
    private func updatePeerSnapshot() {
        let snapshot = connectedPeers
        stateLock.lock()
        _connectedPeersSnapshot = snapshot
        stateLock.unlock()
    }
    
    // MARK: - Private Methods
    
    private func setupPeripheralService() {
        // Create message characteristic (read, write, notify)
        messageCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.messageCharacteristicUUID,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        
        // Create device ID characteristic (read only)
        deviceIDCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.deviceIDCharacteristicUUID,
            properties: [.read],
            value: localDeviceID.uuidString.data(using: .utf8),
            permissions: [.readable]
        )
        
        // Create public key characteristic for ECDH key exchange (read only)
        let publicKeyCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.publicKeyCharacteristicUUID,
            properties: [.read],
            value: DeviceIdentity.shared.publicKeyData,
            permissions: [.readable]
        )
        
        // Create signing key characteristic for ECDSA verification (read only)
        let signingKeyCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.signingKeyCharacteristicUUID,
            properties: [.read],
            value: DeviceIdentity.shared.signingPublicKeyData,
            permissions: [.readable]
        )
        
        // Create service
        let service = CBMutableService(
            type: BLEConstants.meshServiceUUID,
            primary: true
        )
        service.characteristics = [
            messageCharacteristic!,
            deviceIDCharacteristic!,
            publicKeyCharacteristic,
            signingKeyCharacteristic
        ]
        
        peripheralManager.add(service)
        
        MeshLogger.bluetooth.info("Peripheral service configured with encryption keys")
    }
    
    private func scheduleReconnect(for peer: Peer) {
        guard peer.reconnectAttempts < BLEConstants.maxReconnectAttempts else {
            MeshLogger.connection.warning("Max reconnect attempts reached for: \(peer.name)")
            return
        }
        
        peer.reconnectAttempts += 1
        
        let delay = BLEConstants.reconnectDelay * Double(peer.reconnectAttempts)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            
            if peer.state == .disconnected {
                MeshLogger.connection.info("Attempting reconnect \(peer.reconnectAttempts) for: \(peer.name)")
                self.connect(to: peer)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            self.centralState = central.state
        }
        
        MeshLogger.bluetooth.info("Central state: \(central.state.rawValue)")
        
        if central.state == .poweredOn {
            startScanning()
        }
    }
    
    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssiValue = RSSI.intValue
        
        // Filter out weak signals
        guard rssiValue > -90 else { return }
        
        DispatchQueue.main.async {
            if let existingPeer = self.discoveredPeers[peripheral.identifier] {
                existingPeer.updateRSSI(rssiValue)
            } else {
                let peer = Peer(peripheral: peripheral, rssi: rssiValue)
                self.discoveredPeers[peripheral.identifier] = peer
                
                MeshLogger.bluetooth.deviceDiscovered(
                    name: peer.name,
                    rssi: rssiValue,
                    uuid: peripheral.identifier.uuidString
                )
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pendingConnections.remove(peripheral.identifier)
        peripheral.delegate = self
        
        // Discover services
        peripheral.discoverServices([BLEConstants.meshServiceUUID])
        
        MeshLogger.connection.info("Connected to peripheral: \(peripheral.name ?? "Unknown")")
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pendingConnections.remove(peripheral.identifier)
        
        DispatchQueue.main.async {
            if let peer = self.discoveredPeers[peripheral.identifier] {
                peer.updateState(.failed)
            }
        }
        
        MeshLogger.connection.error("Failed to connect: \(peripheral.name ?? "Unknown") - \(error?.localizedDescription ?? "unknown")")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            if let peer = self.connectedPeers[peripheral.identifier] {
                peer.updateState(.disconnected)
                self.connectedPeers.removeValue(forKey: peripheral.identifier)
                self.updatePeerSnapshot()
                self.onPeerDisconnected?(peer)
                
                // Attempt reconnect
                self.scheduleReconnect(for: peer)
            }
        }
        
        MeshLogger.connection.deviceDisconnected(
            name: peripheral.name ?? "Unknown",
            uuid: peripheral.identifier.uuidString
        )
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            MeshLogger.bluetooth.error("Service discovery error: \(error!.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else { return }
        
        for service in services where service.uuid == BLEConstants.meshServiceUUID {
            // Discover all characteristics including encryption keys
            peripheral.discoverCharacteristics(
                [
                    BLEConstants.messageCharacteristicUUID,
                    BLEConstants.deviceIDCharacteristicUUID,
                    BLEConstants.publicKeyCharacteristicUUID,
                    BLEConstants.signingKeyCharacteristicUUID
                ],
                for: service
            )
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            MeshLogger.bluetooth.error("Characteristic discovery error: \(error!.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            switch characteristic.uuid {
            case BLEConstants.messageCharacteristicUUID:
                // Subscribe to notifications
                peripheral.setNotifyValue(true, for: characteristic)
                
                // Store reference in peer
                DispatchQueue.main.async {
                    if let peer = self.discoveredPeers[peripheral.identifier] {
                        peer.messageCharacteristic = characteristic
                    }
                }
                
            case BLEConstants.publicKeyCharacteristicUUID:
                // Read peer's ECDH public key for encryption
                peripheral.readValue(for: characteristic)
                
            case BLEConstants.signingKeyCharacteristicUUID:
                // Read peer's ECDSA signing key for verification
                peripheral.readValue(for: characteristic)
                
            case BLEConstants.deviceIDCharacteristicUUID:
                // Read device ID
                peripheral.readValue(for: characteristic)
                
            default:
                break
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else {
            if let error = error {
                MeshLogger.bluetooth.error("Read value error: \(error.localizedDescription)")
            }
            return
        }
        
        switch characteristic.uuid {
        case BLEConstants.messageCharacteristicUUID:
            // Message data received
            DispatchQueue.main.async {
                if let peer = self.connectedPeers[peripheral.identifier] {
                    self.onMessageReceived?(data, peer)
                }
            }
            
        case BLEConstants.publicKeyCharacteristicUUID:
            // Received peer's ECDH public key - store for encryption
            DispatchQueue.main.async {
                if let peer = self.discoveredPeers[peripheral.identifier] {
                    do {
                        try EncryptionService.shared.storePeerPublicKey(data, for: peer.id)
                        peer.hasExchangedKeys = true
                        MeshLogger.app.info("Received ECDH public key from \(peer.name)")
                        
                        // Check if peer is now fully connected
                        self.checkPeerConnectionComplete(peer, peripheral: peripheral)
                    } catch {
                        MeshLogger.app.error("Failed to store peer public key: \(error)")
                    }
                }
            }
            
        case BLEConstants.signingKeyCharacteristicUUID:
            // Received peer's ECDSA signing key - store for verification
            DispatchQueue.main.async {
                if let peer = self.discoveredPeers[peripheral.identifier] {
                    do {
                        try EncryptionService.shared.storePeerSigningKey(data, for: peer.id)
                        peer.hasExchangedSigningKeys = true
                        MeshLogger.app.info("Received ECDSA signing key from \(peer.name)")
                        
                        // Check if peer is now fully connected
                        self.checkPeerConnectionComplete(peer, peripheral: peripheral)
                    } catch {
                        MeshLogger.app.error("Failed to store peer signing key: \(error)")
                    }
                }
            }
            
        case BLEConstants.deviceIDCharacteristicUUID:
            // Received device ID
            if let deviceIDString = String(data: data, encoding: .utf8),
               let deviceID = UUID(uuidString: deviceIDString) {
                DispatchQueue.main.async {
                    if let peer = self.discoveredPeers[peripheral.identifier] {
                        peer.meshDeviceID = deviceID
                        MeshLogger.app.debug("Received mesh device ID from \(peer.name): \(deviceID.uuidString.prefix(8))")
                    }
                }
            }
            
        default:
            break
        }
    }
    
    /// Check if peer has completed all key exchanges and mark as connected
    private func checkPeerConnectionComplete(_ peer: Peer, peripheral: CBPeripheral) {
        // Peer is fully connected when we have message characteristic and both keys
        guard peer.messageCharacteristic != nil,
              peer.hasExchangedKeys,
              peer.hasExchangedSigningKeys else {
            return
        }
        
        // Mark as connected
        peer.updateState(.connected)
        connectedPeers[peripheral.identifier] = peer
        updatePeerSnapshot()
        onPeerConnected?(peer)
        
        MeshLogger.connection.deviceConnected(
            name: peer.name,
            uuid: peripheral.identifier.uuidString
        )
        MeshLogger.app.info("Peer \(peer.name) fully connected with encryption keys exchanged")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            MeshLogger.message.error("Write error: \(error.localizedDescription)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            MeshLogger.bluetooth.error("Notification state error: \(error.localizedDescription)")
        } else {
            MeshLogger.bluetooth.debug("Notifications enabled for: \(characteristic.uuid)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        
        DispatchQueue.main.async {
            self.discoveredPeers[peripheral.identifier]?.updateRSSI(RSSI.intValue)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BluetoothManager: CBPeripheralManagerDelegate {
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        DispatchQueue.main.async {
            self.peripheralState = peripheral.state
        }
        
        MeshLogger.bluetooth.info("Peripheral state: \(peripheral.state.rawValue)")
        
        if peripheral.state == .poweredOn {
            startAdvertising()
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            MeshLogger.bluetooth.error("Failed to add service: \(error.localizedDescription)")
        } else {
            MeshLogger.bluetooth.info("Service added successfully")
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            MeshLogger.bluetooth.error("Advertising error: \(error.localizedDescription)")
        } else {
            MeshLogger.bluetooth.info("Advertising started successfully")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribedCentrals.insert(central)
        
        // Create peer for this central
        DispatchQueue.main.async {
            let peer = Peer(central: central)
            self.connectedPeers[central.identifier] = peer
            self.updatePeerSnapshot()
            self.onPeerConnected?(peer)
            
            MeshLogger.connection.deviceConnected(
                name: peer.name,
                uuid: central.identifier.uuidString
            )
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.remove(central)
        
        DispatchQueue.main.async {
            if let peer = self.connectedPeers[central.identifier] {
                self.connectedPeers.removeValue(forKey: central.identifier)
                self.updatePeerSnapshot()
                self.onPeerDisconnected?(peer)
                
                MeshLogger.connection.deviceDisconnected(
                    name: peer.name,
                    uuid: central.identifier.uuidString
                )
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BLEConstants.messageCharacteristicUUID,
               let data = request.value {
                
                // Find or create peer for this central
                DispatchQueue.main.async {
                    var peer = self.connectedPeers[request.central.identifier]
                    
                    if peer == nil {
                        peer = Peer(central: request.central)
                        self.connectedPeers[request.central.identifier] = peer
                        self.updatePeerSnapshot()
                    }
                    
                    if let peer = peer {
                        self.onMessageReceived?(data, peer)
                    }
                }
                
                // Respond to write request
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == BLEConstants.deviceIDCharacteristicUUID {
            request.value = localDeviceID.uuidString.data(using: .utf8)
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }
}

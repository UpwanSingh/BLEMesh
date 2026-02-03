import Foundation
import CoreBluetooth

/// Represents a discovered BLE peer device
final class Peer: Identifiable, ObservableObject, Hashable {
    let id: UUID
    let peripheral: CBPeripheral?
    let central: CBCentral?
    
    @Published var name: String
    @Published var rssi: Int
    @Published var state: ConnectionState
    @Published var lastSeen: Date
    @Published var messageCharacteristic: CBCharacteristic?
    @Published var reconnectAttempts: Int = 0
    
    /// Tracks if ECDH public key has been exchanged
    @Published var hasExchangedKeys: Bool = false
    
    /// Tracks if ECDSA signing key has been exchanged
    @Published var hasExchangedSigningKeys: Bool = false
    
    /// Mesh network device ID (different from BLE peripheral ID)
    @Published var meshDeviceID: UUID?
    
    /// Actual negotiated MTU
    var negotiatedMTU: Int = BLEConstants.defaultMTU
    
    enum ConnectionState: String, CustomStringConvertible {
        case discovered = "Discovered"
        case connecting = "Connecting"
        case connected = "Connected"
        case disconnected = "Disconnected"
        case failed = "Failed"
        
        var description: String { rawValue }
    }
    
    /// Convenience computed property to check if peer is connected
    var isConnected: Bool {
        state == .connected
    }
    
    /// Initialize from peripheral (Central role discovered this)
    init(peripheral: CBPeripheral, rssi: Int) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        self.central = nil
        self.name = peripheral.name ?? "Unknown-\(peripheral.identifier.uuidString.prefix(4))"
        self.rssi = rssi
        self.state = .discovered
        self.lastSeen = Date()
    }
    
    /// Initialize from central (Peripheral role - someone connected to us)
    init(central: CBCentral) {
        self.id = central.identifier
        self.peripheral = nil
        self.central = central
        self.name = "Central-\(central.identifier.uuidString.prefix(4))"
        self.rssi = 0
        self.state = .connected
        self.lastSeen = Date()
    }
    
    func updateRSSI(_ newRSSI: Int) {
        self.rssi = newRSSI
        self.lastSeen = Date()
    }
    
    /// Initialize with just an ID (for routed peers we haven't directly seen)
    init(id: UUID, name: String? = nil) {
        self.id = id
        self.peripheral = nil
        self.central = nil
        self.name = name ?? "Device-\(id.uuidString.prefix(4))"
        self.rssi = 0
        self.state = .discovered
        self.lastSeen = Date()
    }
    
    func updateState(_ newState: ConnectionState) {
        self.state = newState
        if newState == .connected {
            reconnectAttempts = 0
        }
    }
    
    // MARK: - Hashable
    
    static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Debug Description

extension Peer: CustomDebugStringConvertible {
    var debugDescription: String {
        "Peer(\(name), RSSI: \(rssi), State: \(state))"
    }
}

import Foundation
import OSLog

/// Centralized logging using OSLog for structured debugging
enum MeshLogger {
    private static let subsystem = "com.blemesh.app"
    
    /// Logger for Bluetooth operations
    static let bluetooth = Logger(subsystem: subsystem, category: "Bluetooth")
    
    /// Logger for message operations
    static let message = Logger(subsystem: subsystem, category: "Message")
    
    /// Logger for relay operations
    static let relay = Logger(subsystem: subsystem, category: "Relay")
    
    /// Logger for connection events
    static let connection = Logger(subsystem: subsystem, category: "Connection")
    
    /// Logger for chunk operations
    static let chunk = Logger(subsystem: subsystem, category: "Chunk")
    
    /// Logger for general app events
    static let app = Logger(subsystem: subsystem, category: "App")
}

// MARK: - Convenience Extensions

extension Logger {
    func deviceDiscovered(name: String, rssi: Int, uuid: String) {
        self.info("📱 DISCOVERED: \(name) | RSSI: \(rssi) | UUID: \(uuid)")
    }
    
    func deviceConnected(name: String, uuid: String) {
        self.info("✅ CONNECTED: \(name) | UUID: \(uuid)")
    }
    
    func deviceDisconnected(name: String, uuid: String) {
        self.info("❌ DISCONNECTED: \(name) | UUID: \(uuid)")
    }
    
    func messageSent(id: String, to: String, size: Int) {
        self.info("📤 SENT: ID=\(id) | TO=\(to) | SIZE=\(size) bytes")
    }
    
    func messageReceived(id: String, from: String, size: Int) {
        self.info("📥 RECEIVED: ID=\(id) | FROM=\(from) | SIZE=\(size) bytes")
    }
    
    func messageRelayed(id: String, ttl: Int, to: String) {
        self.info("🔄 RELAYED: ID=\(id) | TTL=\(ttl) | TO=\(to)")
    }
    
    func chunkSent(messageId: String, index: Int, total: Int) {
        self.debug("📦 CHUNK SENT: \(messageId) [\(index + 1)/\(total)]")
    }
    
    func chunkReceived(messageId: String, index: Int, total: Int) {
        self.debug("📦 CHUNK RECEIVED: \(messageId) [\(index + 1)/\(total)]")
    }
}

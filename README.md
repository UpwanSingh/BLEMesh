# BLE Mesh Messaging Prototype

A minimal but fully functional Bluetooth Low Energy mesh-style messaging prototype for iOS.

## Features

- **Dual Role BLE Node**: Each device acts as both Central and Peripheral simultaneously
- **Device Discovery**: Automatic discovery of nearby devices with RSSI monitoring
- **Message Chunking**: Automatic splitting and reassembly of messages exceeding BLE MTU
- **Mesh Relay**: Messages are automatically relayed with TTL=3 to simulate mesh behavior
- **Duplicate Prevention**: Message ID caching prevents infinite loops
- **Auto-Reconnect**: Automatic reconnection attempts on disconnect
- **Structured Logging**: OSLog-based debug logging for all operations

## Project Structure

```
BLEMesh/
├── App/
│   └── BLEMeshApp.swift          # App entry point
├── Core/
│   ├── Constants.swift           # BLE UUIDs and configuration
│   └── Logger.swift              # OSLog setup
├── Models/
│   ├── Peer.swift                # Discovered device model
│   └── Message.swift             # Message and chunk models
├── Managers/
│   └── BluetoothManager.swift    # Central + Peripheral BLE logic
├── Services/
│   └── MessageRelayService.swift # Message routing and relay
├── ViewModels/
│   └── ChatViewModel.swift       # UI state management
├── Views/
│   └── ContentView.swift         # SwiftUI views
└── Info.plist                    # Permissions and capabilities
```

## Setup Instructions

### Prerequisites

- Xcode 15.0+
- iOS 16.0+
- Two or more physical iOS devices (BLE doesn't work in Simulator)
- XcodeGen installed (`brew install xcodegen`)

### Generate Xcode Project

```bash
cd /Users/upwansingh/Desktop/Mesh
xcodegen generate
```

### Open in Xcode

```bash
open BLEMesh.xcodeproj
```

### Configure Signing

1. Open the project in Xcode
2. Select the `BLEMesh` target
3. Go to "Signing & Capabilities"
4. Select your Development Team
5. Xcode will automatically manage signing

### Required Capabilities (Already Configured)

The `Info.plist` already includes:

- `NSBluetoothAlwaysUsageDescription` - Bluetooth permission
- `NSBluetoothPeripheralUsageDescription` - Peripheral permission
- `UIBackgroundModes`:
  - `bluetooth-central`
  - `bluetooth-peripheral`

## Testing with Two Devices

### Step 1: Install on Both Devices

1. Connect first iPhone to Mac
2. Select device in Xcode, build and run (⌘R)
3. Connect second iPhone to Mac
4. Select second device in Xcode, build and run (⌘R)

### Step 2: Grant Permissions

On each device:
1. Allow Bluetooth permission when prompted
2. App will automatically start scanning and advertising

### Step 3: Connect Devices

1. Open "Peers" tab on both devices
2. Wait for devices to discover each other (few seconds)
3. Tap "Connect" on one device to connect to the other
4. Verify connection shows "Connected" state

### Step 4: Send Messages

1. Open "Messages" tab
2. Type a message and tap Send
3. Message should appear on the other device
4. Check "Debug" tab for statistics

### Step 5: Verify Mesh Relay

With 3+ devices:
1. Connect Device A ↔ Device B
2. Connect Device B ↔ Device C
3. Send message from Device A
4. Message should relay through B to reach C
5. Check TTL decrements (3 → 2 → 1)

## Debug Logging

View logs in Console.app or Xcode console:

```
📱 DISCOVERED: BLEMesh-iPhone | RSSI: -45 | UUID: ABC123
✅ CONNECTED: BLEMesh-iPhone | UUID: ABC123
📤 SENT: ID=xyz789 | TO=BLEMesh-iPhone | SIZE=128 bytes
📥 RECEIVED: ID=xyz789 | FROM=BLEMesh-iPhone | SIZE=128 bytes
🔄 RELAYED: ID=xyz789 | TTL=2 | TO=BLEMesh-iPad
```

Filter by subsystem: `com.blemesh.app`

Categories:
- `Bluetooth` - BLE state changes
- `Connection` - Connect/disconnect events
- `Message` - Send/receive operations
- `Relay` - Mesh relay operations
- `Chunk` - Chunking/assembly

## Architecture

### MVVM Pattern

```
Views (SwiftUI) 
    ↓ bindings
ChatViewModel (@MainActor)
    ↓ depends on
MessageRelayService (message routing)
    ↓ uses
BluetoothManager (BLE operations)
```

### Message Flow

```
1. User types message
2. ChatViewModel.sendMessage()
3. MessageRelayService.sendMessage()
   - Mark message ID as seen
   - Serialize to JSON
   - Chunk if > MTU
4. BluetoothManager.broadcast()
   - Send chunks to all connected peers
5. On receive:
   - Assemble chunks
   - Check duplicate (message ID cache)
   - Store message
   - Relay with TTL-1
```

## Troubleshooting

### Devices Not Discovering Each Other

- Ensure Bluetooth is ON
- Check distance (< 10 meters recommended)
- Force close and restart app
- Toggle Airplane Mode on/off

### Messages Not Sending

- Verify connection state is "Connected"
- Check Debug tab for connected peers count
- View OSLog for error messages

### App Crashes

- Check console for crash logs
- Ensure iOS 16.0+ on device
- Try clean build (⌘⇧K then ⌘B)

## Known Limitations

- No persistence (messages stored in memory only)
- No encryption (placeholder only)
- Requires foreground for best performance
- Maximum ~7 simultaneous BLE connections (iOS limit)

## Future Improvements

- [ ] Message persistence with SwiftData
- [ ] AES-GCM encryption
- [ ] Delivery acknowledgments
- [ ] Background fetch optimization
- [ ] Mesh routing optimization
- [ ] Connection quality monitoring

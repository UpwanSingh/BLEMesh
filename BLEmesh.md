BLE Mesh Logic Implementation Documentation
This document provides a deep dive into the Bluetooth Low Energy (BLE) mesh implementation within the BLEMesh project. It covers broadcasting, receiving, routing, and message relaying mechanisms.
Core Components & Files
1. 
BluetoothManager.swift
The heartbeat of the BLE operations. It implements a dual-role (Central and Peripheral) manager.
* Central Role: Scans for other mesh devices, initiates connections, and listens for characteristic updates (notifications).
* Peripheral Role: Advertises the mesh service, defines the GATT structure, and handles incoming write/read requests from other centrals.
* Key Methods:
    * startScanning() / startAdvertising(): Initiation of discovery/presence.
    * broadcast(data:excluding:): Sends data to all connected peers via characteristic notifications.
    * send(data:to:): Targeted data transmission to a specific connected peer.

2. 
MessageRelayService.swift
Handles high-level message logic above the raw BLE layer.
* Relaying: Implements the core mesh logic. When a message is received, it checks if it has been "seen" before (using messageHash). If not, and if the TTL > 1, it rebroadcasts the message to all other connected peers.
* Chunking: Uses ChunkCreator to split large messages into BLE MTU-sized chunks.
* Reassembly: Uses ChunkAssembler to rebuild messages from incoming chunks.


3. 
RoutingService.swift
Responsible for finding paths through the mesh network.
* AODV Protocol: Implements an Ad hoc On-Demand Distance Vector routing protocol.
* Route Discovery: Initiates RouteRequest (RREQ) broadcasts to find a specific device. Handles RouteReply (RREP) to establish a path.
* Routing Table: Maintains a map of destinationID to nextHopID with hopCount and path info.
4. 
Message.swift
Defines the user-facing message structures and chunking utilities.
* MeshMessage: The primary UI-level message model.
* MessageChunk: The unit of transmission over BLE.
* ChunkCreator: Logic for splitting MessageEnvelope data into chunks.
* ChunkAssembler: Logic for re-assembling chunks into a complete data blob.


5. 
MessageEnvelope.swift
The "wrapper" for all data sent over the mesh.
* Contains metadata like originID, destinationID, ttl (Time-To-Live), and hopPath.
* Supports both User Messages and Control Messages.


6. 
RouteMessages.swift
Defines control message types:
* RREQ (Route Request), RREP (Route Reply), RERR (Route Error), ANNOUNCE (Presence), ACK (Acknowledgement), and READ (Read Receipt).


User Flow: Message Broadcasting
1. Initiation: User types a message in ChatView and hits send.
2. ViewModel: ChatViewModel calls MessageRelayService.sendBroadcastMessage.
3. Enveloping: MessageRelayService creates a MessageEnvelope with destinationID = nil.
4. Serialization: The envelope is serialized to JSON and then to Data.
5. Chunking: ChunkCreator.createChunks splits the data into small pieces (MTU size - header).
6. BLE Transmission: BluetoothManager.broadcast is called for each chunk.
    * If acting as Peripheral: Calls updateValue(_:for:onSubscribedCentrals:).
    * If acting as Central: Iterates through connected peripherals and calls writeValue(_:for:type:).

User Flow: Message Receiving & Relaying
1. BLE Reception:
    * Central: peripheral(_:didUpdateValueFor:error:) is called when a peer sends a notification.
    * Peripheral: peripheralManager(_:didReceiveWrite:) is called when a central writes to the message characteristic.
2. Raw Data: BluetoothManager emits the data via the onMessageReceived callback.
3. Assembly: MessageRelayService receives the chunk and passes it to ChunkAssembler. If it's the last chunk, it returns the complete Data.
4. Envelope Processing: The complete data is deserialized into a MessageEnvelope.
5. Deduplication: MessageRelayService checks seenMessageIDs. If already seen, the message is ignored.
6. Relay Action:
    * Local Processing: If the message is for the local device or a broadcast, it's deserialized into a MeshMessage and added to receivedMessages.
    * Forwarding: If ttl > 1, MessageRelayService decrements the TTL, appends the local device ID to hopPath, and calls broadcastEnvelope to relay it to all other peers (excluding the sender).

Technical Details for Replication
BLE Specifications
* Service UUID: 12345678-1234-5678-1234-567812345678
* Message Characteristic: 12345678-1234-5678-1234-567812345679 (Read/Write/Notify)
* MTU Strategy: Fixed at 182 bytes (BLEConstants.defaultMTU) to ensure compatibility across devices.
* Chunk Header: 20 bytes for metadata (id, index, total, flags).
Routing Strategy
* Max TTL: 3 hops (BLEConstants.maxTTL).
* Deduplication: Based on messageID and sequenceNumber.
* Relay Loop Prevention: Devices track hopPath in the envelope to avoid sending back to nodes already in the path.
Logging & Debugging
The system uses 

Logger.swift with categories for Bluetooth, Message, Relay, and Connection, allowing for granular tracking of the mesh state in Xcode's console or via os_log.


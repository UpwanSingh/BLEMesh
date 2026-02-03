import SwiftUI

@main
struct BLEMeshApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState.bluetoothManager)
                .environmentObject(appState.routingService)
                .environmentObject(appState.messageRelayService)
                .environmentObject(appState.chatViewModel)
        }
    }
}

/// Centralized app state to ensure single instance of dependencies
@MainActor
final class AppState: ObservableObject {
    let bluetoothManager: BluetoothManager
    let routingService: RoutingService
    let messageRelayService: MessageRelayService
    let chatViewModel: ChatViewModel
    
    init() {
        let btManager = BluetoothManager()
        let routing = RoutingService()
        routing.configure(bluetoothManager: btManager)
        
        let relayService = MessageRelayService(
            bluetoothManager: btManager,
            routingService: routing
        )
        
        let viewModel = ChatViewModel(
            bluetoothManager: btManager,
            routingService: routing,
            messageRelayService: relayService
        )
        
        self.bluetoothManager = btManager
        self.routingService = routing
        self.messageRelayService = relayService
        self.chatViewModel = viewModel
    }
}

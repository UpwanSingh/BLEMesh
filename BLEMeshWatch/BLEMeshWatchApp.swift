import SwiftUI

@main
struct BLEMeshWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchSOSView()
                .environmentObject(model)
        }
    }
}

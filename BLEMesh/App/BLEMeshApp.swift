import SwiftUI
import SwiftData
import MeshCore

@main
struct BLEMeshApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var mesh: MeshService
    @StateObject private var speaker = Speaker()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITest = arguments.contains("-uiTesting")
        let isUnitTest = NSClassFromString("XCTestCase") != nil && !isUITest
        if isUITest {
            // Clean, deterministic state for UI tests.
            UserDefaults.standard.set(!arguments.contains("-showOnboarding"), forKey: "hasCompletedOnboarding")
            UserDefaults.standard.set("Tester", forKey: "mesh.nickname")
        }
        let demo = arguments.contains("-demoMesh") || isUITest || isUnitTest
        // Demo mode never touches the real store, snapshot (outbox/group keys) or identity.
        let container = PersistenceController.makeContainer(inMemory: demo)
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _mesh = StateObject(wrappedValue: MeshService(mode: demo ? .demo : .bluetooth, container: container,
                                                      settings: settings, persistSnapshot: !demo))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(mesh)
                .environmentObject(settings)
                .environmentObject(speaker)
                .modelContainer(mesh.container)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { mesh.appDidEnterBackground() }
            if phase == .active { mesh.appDidBecomeActive() }
        }
    }
}

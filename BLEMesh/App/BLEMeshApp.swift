import SwiftUI
import SwiftData
import MeshCore

@main
struct BLEMeshApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var mesh: MeshService
    @StateObject private var speaker = Speaker()
    @StateObject private var trust: TrustStore
    @Environment(\.scenePhase) private var scenePhase
    private let watchBridge: WatchBridge?

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
        if isUITest { settings.resetToDefaults() }
        // Demo/test runs keep trust state (and the medical ID) separate from the real ones.
        let trust = demo ? TrustStore(defaults: UserDefaults(suiteName: "demo.trust") ?? .standard, medicalAccount: "medical.demo")
                         : TrustStore()
        if isUITest { trust.wipe() }
        _settings = StateObject(wrappedValue: settings)
        _trust = StateObject(wrappedValue: trust)
        // UI tests use the offline engine: deterministic, and no load on the system's model service.
        let service = MeshService(mode: demo ? .demo : .bluetooth, container: container,
                                  settings: settings, trust: trust, ai: isUITest ? OfflineKnowledgeEngine() : nil,
                                  persistSnapshot: !demo)
        if demo && arguments.contains("-demoSpam") {
            // A scam broadcast for exercising the spam filter in UI tests.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak service] in
                service?.demoBroadcast(.text("FREE MONEY for flood victims!! click here bit.ly/relief-cash"), from: "Kabir")
            }
        }
        _mesh = StateObject(wrappedValue: service)
        // Apple Watch SOS goes through this phone (not in unit tests, which drive the bridge directly).
        watchBridge = isUnitTest ? nil : WatchBridge(mesh: service)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(mesh)
                .environmentObject(settings)
                .environmentObject(speaker)
                .environmentObject(trust)
                .modelContainer(mesh.container)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { mesh.appDidEnterBackground() }
            if phase == .active { mesh.appDidBecomeActive() }
        }
    }
}

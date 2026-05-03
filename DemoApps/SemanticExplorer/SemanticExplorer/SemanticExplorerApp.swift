import SwiftUI

@main
struct SemanticExplorerApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppState.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await appState.start()
                }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .active:
                        appState.applicationDidBecomeActive()
                    case .background:
                        appState.applicationDidEnterBackground()
                    default:
                        break
                    }
                }
        }
    }
}

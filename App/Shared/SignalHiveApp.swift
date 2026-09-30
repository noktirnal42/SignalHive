import SwiftUI

@main
struct SignalHiveApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        #if os(macOS)
        .windowStyle(.automatic)
        .defaultSize(width: 1280, height: 780)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 480, minHeight: 420)
        }
        #endif
    }
}

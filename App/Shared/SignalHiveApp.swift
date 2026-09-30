import SwiftUI

@main
struct SignalHiveApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(SignalHiveAppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel()
    @State private var aviation = AviationModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(aviation)
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

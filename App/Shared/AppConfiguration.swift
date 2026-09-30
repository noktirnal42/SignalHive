import Foundation

enum AppConfiguration {
    /// Folder URL that contains the hosted `manifest.json` and state packs. `nil` until hosting exists;
    /// a developer can point the app at any server by setting the `packBaseURL` default
    /// (`defaults write com.noktirnal42.SignalHive packBaseURL https://example.com/packs`).
    static var packBaseURL: URL? {
        guard let text = UserDefaults.standard.string(forKey: "packBaseURL")?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }
        return URL(string: text)
    }

    /// Enables the built-in realistic Alabama dataset for UI verification and demos.
    /// Launch with `-mockData YES` or set the `mockData` default.
    static var usesMockData: Bool {
        UserDefaults.standard.bool(forKey: "mockData")
    }
}

import SwiftUI
import SignalHiveCore

// MARK: - App model

@Observable
@MainActor
final class AppModel: ObservableObject {

    // Data
    @ObservationIgnored let packs: PackStore
    @ObservationIgnored let browse: any BrowseDataSource
    @ObservationIgnored private var userData: UserDatabase?
    var states: [StateAvailability] = []
    /// Live progress for installs in flight (the pack store only reports milestones).
    var liveStatus: [String: PackStatus] = [:]
    /// Why the hosted pack list is unavailable. Not fatal: local build still works.
    var manifestNote: String?
    var lastError: String?
    var databaseError: String?
    var databaseReady = false

    // "Build from FCC on this Mac"
    var importActive = false
    var importProgress: PackBuildProgress?
    var lastImportSummary: String?
    var localBuildServices: Set<ULSService.ID> = [ULSService.lmPriv.rawValue, ULSService.lmComm.rawValue]
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    // Codeplug
    var codeplug = Codeplug()
    var codeplugs: [Codeplug] = []

    // Cross-view navigation intent
    var pendingScanFrequency: Double?

    @ObservationIgnored private var didBootstrap = false

    // MARK: Locations

    /// `-supportDirectory <path>` on the command line (or the same UserDefaults key) redirects all app data,
    /// so a test run never touches the real library.
    static var supportDirectory: URL {
        if let override = UserDefaults.standard.string(forKey: "supportDirectory"), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SignalHive", isDirectory: true)
    }
    static var userDataURL: URL { supportDirectory.appendingPathComponent("UserData.sqlite") }
    static var packDirectory: URL { supportDirectory.appendingPathComponent("Packs", isDirectory: true) }
    static var localPacksDirectory: URL { supportDirectory.appendingPathComponent("LocalPacks", isDirectory: true) }
    static var workDirectory: URL { supportDirectory.appendingPathComponent("Work", isDirectory: true) }
    static var legacyDatabaseURL: URL { supportDirectory.appendingPathComponent("SignalHive.sqlite") }

    // MARK: Init

    convenience init() {
        let packs = PackStore(manifestBaseURL: AppConfiguration.packBaseURL, installDirectory: Self.packDirectory)
        if AppConfiguration.usesMockData {
            self.init(browse: MockBrowseDataSource(), packs: packs)
        } else {
            self.init(browse: PackBrowseDataSource(packs: packs), packs: packs)
        }
        Task { await bootstrap() }
    }

    /// Injectable form for previews and tests.
    init(browse: any BrowseDataSource, packs: PackStore) {
        self.browse = browse
        self.packs = packs
    }

    var installedCount: Int {
        states.filter { if case .installed = $0.status { return true } else { return false } }.count
    }

    func status(for code: String) -> PackStatus {
        liveStatus[code] ?? states.first { $0.code == code }?.status ?? .notInstalled(sizeBytes: nil)
    }

    // MARK: Bootstrap

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            let db = try await UserDatabase.open(at: Self.userDataURL.path)
            userData = db
            databaseReady = true
            _ = try await db.migrateCodeplugsIfNeeded(fromLegacy: Self.legacyDatabaseURL.path)
            codeplugs = try await db.codeplugs()
            if let first = codeplugs.first { codeplug = first }
        } catch {
            databaseError = error.localizedDescription
        }
        await refreshManifest()
        await refreshStates()
        writeDiagnostics()
    }

    /// A plain-text snapshot of what the app can see, saved next to its data (`diagnostics.txt`) so problems
    /// like "the dongle is not listed" can be explained without guessing.
    func writeDiagnostics() {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        var lines = [
            "SignalHive diagnostics \(Date().formatted(date: .abbreviated, time: .standard))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), sandboxed: \(sandboxed)",
            "Support directory: \(Self.supportDirectory.path)",
            "Installed FCC packs: \(installedCount)",
            "Pack server: \(manifestNote ?? "reachable")",
            "",
            "RTL-SDR library: \(RTLSDRLibrary.status.isAvailable ? "available" : "NOT available")",
            RTLSDRLibrary.status.summary,
        ]
        if let error = lastError { lines.append("Last error: \(error)") }
        try? lines.joined(separator: "\n").write(to: Self.supportDirectory.appendingPathComponent("diagnostics.txt"),
                                                atomically: true, encoding: .utf8)
    }

    func refreshManifest() async {
        guard !AppConfiguration.usesMockData else {
            manifestNote = "Demo data is active. Launch without -mockData to use installed FCC packs."
            return
        }
        do {
            try await packs.refreshManifest()
            manifestNote = nil
        } catch {
            manifestNote = error.localizedDescription
        }
    }

    func refreshStates() async {
        states = await browse.states()
    }

    // MARK: Packs

    func install(state: String) async {
        lastError = nil
        do {
            try await packs.install(state: state) { [weak self] status in
                Task { @MainActor in self?.liveStatus[state] = status }
            }
        } catch {
            lastError = error.localizedDescription
        }
        liveStatus[state] = nil
        await refreshStates()
    }

    func removePack(state: String) async {
        do {
            try await packs.remove(state: state)
        } catch {
            lastError = error.localizedDescription
        }
        await refreshStates()
    }

    // MARK: Local build

    func buildLocally(states requested: Set<String>) async {
        guard !importActive else { return }
        importActive = true
        importProgress = nil
        lastImportSummary = nil
        lastError = nil
        let task = Task { await performLocalBuild(requested) }
        buildTask = task
        await task.value
        buildTask = nil
        importActive = false
        importProgress = nil
        for code in requested { liveStatus[code] = nil }
        await refreshStates()
    }

    func cancelImport() {
        buildTask?.cancel()
    }

    private func performLocalBuild(_ requested: Set<String>) async {
        for code in requested { liveStatus[code] = .downloading(progress: 0) }
        let services = ULSService.allCases.filter { localBuildServices.contains($0.id) }
        let service = LocalPackService(workDirectory: Self.workDirectory, outputDirectory: Self.localPacksDirectory)
        do {
            let manifest = try await service.build(services: services, states: requested) { [weak self] progress in
                Task { @MainActor in self?.importProgress = progress }
            }
            let local = PackStore(manifestBaseURL: Self.localPacksDirectory, installDirectory: Self.packDirectory)
            for pack in manifest.packs { try await local.install(state: pack.stateCode) { _ in } }
            let built = manifest.packs.map(\.stateCode).sorted().joined(separator: ", ")
            lastImportSummary = "Built \(built) from FCC data (snapshot \(manifest.fccSnapshotDate))"
        } catch is CancellationError {
            lastImportSummary = nil
        } catch {
            if Task.isCancelled { return }
            lastError = error.localizedDescription
        }
    }

    // MARK: Codeplug

    func addToCodeplug(channel: CodeplugChannel) {
        codeplug.add(channel: channel)
        persistCodeplug()
    }

    func removeChannel(_ channel: CodeplugChannel) {
        codeplug.remove(channelID: channel.id)
        persistCodeplug()
    }

    func persistCodeplug() {
        guard let userData else { return }
        let plug = codeplug
        Task {
            do {
                try await userData.saveCodeplug(plug)
                codeplugs = try await userData.codeplugs()
            } catch {
                lastError = "Could not save the codeplug: \(error.localizedDescription)"
            }
        }
    }

    func newCodeplug(name: String, target: RadioTarget) {
        codeplug = Codeplug(name: name, target: target)
        persistCodeplug()
    }

    func tuneInScanner(frequencyHz: Double) {
        pendingScanFrequency = frequencyHz
    }
}

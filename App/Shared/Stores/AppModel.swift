import SwiftUI
import SignalHiveCore

// MARK: - App model

@Observable
@MainActor
final class AppModel: ObservableObject {

    // Data
    @ObservationIgnored let packs: PackStore
    @ObservationIgnored let browse: any BrowseDataSource
    /// On-device language models downloaded from Hugging Face (AI Lab).
    let models = ModelLibrary()
    /// The Decoder Hub's live session (one dongle, one decoder).
    let liveDecoder = LiveDecoderModel()
    @ObservationIgnored private var userData: UserDatabase?
    var states: [StateAvailability] = []
    /// Live progress for installs in flight (the pack store only reports milestones).
    var liveStatus: [String: PackStatus] = [:]
    /// Why the hosted pack list is unavailable. Not fatal: local build still works.
    var manifestNote: String?
    var lastError: String?
    var databaseError: String?
    var databaseReady = false
    /// Result of the RTL-SDR self-test (`-testRTLSDR YES` on the command line), shown in diagnostics.txt.
    @ObservationIgnored private var selfTestLines: [String] = []

    // "Build from FCC on this Mac"
    var importActive = false
    var importProgress: PackBuildProgress?
    var lastImportSummary: String?
    var localBuildServices: Set<ULSService.ID> = [ULSService.lmPriv.rawValue, ULSService.lmComm.rawValue]
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    // Codeplug
    var codeplug = Codeplug()
    var codeplugs: [Codeplug] = []
    /// The codeplug as it was before the last fix was applied, for one-step undo.
    var codeplugBeforeFix: Codeplug?

    // Cross-view navigation intent
    var pendingScanFrequency: Double?
    /// What the Workshop asked the next screen to start (a tuned frequency, a decoder); that screen takes it on appear.
    var pendingPreset: WorkshopPreset?
    /// The Workshop's "Add source" fix: open the Scanner with its rtl_tcp host field showing.
    var pendingAddNetworkSource = false

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
        if UserDefaults.standard.bool(forKey: "testRTLSDR") { await runRTLSDRSelfTest() }
    }

    /// Opens the first RTL-SDR, streams for a second, and records the outcome in diagnostics.txt. Started by the
    /// `-testRTLSDR YES` launch argument, so the sandboxed app can be checked without clicking through the UI.
    func runRTLSDRSelfTest() async {
        guard let device = await NativeRTLSDRDevice.enumerateDevices().first else {
            selfTestLines = ["RTL-SDR self-test: FAILED - no dongle found."]
            writeDiagnostics()
            return
        }
        let report = await RTLSDRSelfTest.run(device)
        selfTestLines = ["RTL-SDR self-test: \(report.passed ? "PASSED" : "FAILED")"] + report.lines
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
            "RTL-SDR (native driver): \(RTLSDRAvailability.current.isAvailable ? "dongle found" : "no dongle")",
            RTLSDRAvailability.current.summary,
        ]
        if !selfTestLines.isEmpty { lines.append(""); lines += selfTestLines }
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

    /// Installs one state's hosted pack. Returns whether it worked (the reason is in `lastError` when it did not).
    @discardableResult
    func install(state: String) async -> Bool {
        lastError = nil
        let failure = await installHosted(state: state)
        if let failure { lastError = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription }
        return failure == nil
    }

    private func installHosted(state: String) async -> Error? {
        var failure: Error?
        do {
            try await packs.install(state: state) { [weak self] status in
                Task { @MainActor in self?.liveStatus[state] = status }
            }
        } catch {
            failure = error
        }
        liveStatus[state] = nil
        await refreshStates()
        return failure
    }

    func removePack(state: String) async {
        do {
            try await packs.remove(state: state)
        } catch {
            lastError = error.localizedDescription
        }
        await refreshStates()
    }

    // MARK: Get data (several states at once)

    /// One "get data" job: a plan and how far along it is.
    struct DataJob {
        var plan: DataPlan
        var finished: Set<String> = []
        var failures: [String: String] = [:]
        var step = "Starting…"
        var isRunning = true
        var wasCancelled = false
        var summary: String?

        var totalCount: Int { plan.downloads.count + plan.builds.count }
        var completedCount: Int { finished.count + failures.count }
    }

    var dataJob: DataJob?
    @ObservationIgnored private var dataTask: Task<Void, Never>?

    var dataJobRunning: Bool { dataJob?.isRunning == true }

    /// The plan for a set of states, with this Mac's current view of what is installed and what is hosted.
    func dataPlan(for requested: Set<String>, preference: DataSourcePreference, refreshInstalled: Bool) -> DataPlan {
        DataPlan.make(requested: requested,
                      states: states.map { StateAvailability(code: $0.code, name: $0.name, status: status(for: $0.code)) },
                      hostedAvailable: manifestNote == nil && !AppConfiguration.usesMockData,
                      preference: preference,
                      services: ULSService.allCases.filter { localBuildServices.contains($0.id) },
                      refreshInstalled: refreshInstalled)
    }

    /// Runs a plan: hosted packs one after another, then every state that has to be built in ONE pass over the FCC archives.
    func getData(_ plan: DataPlan) async {
        guard !plan.isEmpty, !dataJobRunning, !importActive else { return }
        dataJob = DataJob(plan: plan)
        let task = Task { await runDataJob(plan) }
        dataTask = task
        await task.value
        dataTask = nil
    }

    func cancelDataJob() {
        guard dataJobRunning else { return }
        dataJob?.wasCancelled = true
        dataTask?.cancel()
        buildTask?.cancel()
    }

    func dismissDataJob() {
        if !dataJobRunning { dataJob = nil }
    }

    private func runDataJob(_ plan: DataPlan) async {
        var toBuild = plan.builds.map(\.code)
        for item in plan.downloads {
            if Task.isCancelled { break }
            dataJob?.step = "Downloading \(item.name)…"
            if let failure = await installHosted(state: item.code) {
                if let store = failure as? PackStoreError, case .notInManifest = store {
                    toBuild.append(item.code)           // no hosted pack for it after all: build it with the others
                } else if failure is CancellationError || Task.isCancelled {
                    break
                } else {
                    dataJob?.failures[item.code] = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
                }
            } else {
                dataJob?.finished.insert(item.code)
            }
        }

        if !toBuild.isEmpty, !Task.isCancelled {
            dataJob?.step = "Building \(toBuild.count) state\(toBuild.count == 1 ? "" : "s") from the FCC data…"
            await buildLocally(states: Set(toBuild))
            for code in toBuild {
                if case .installed = status(for: code) {
                    dataJob?.finished.insert(code)
                } else if !(dataJob?.wasCancelled ?? false) {
                    dataJob?.failures[code] = lastError ?? "The build did not produce this state."
                }
            }
        }

        await refreshStates()
        guard var job = dataJob else { return }
        job.isRunning = false
        if job.wasCancelled || Task.isCancelled {
            job.summary = "Cancelled. \(job.finished.count) of \(job.totalCount) finished; what arrived is kept."
        } else if job.failures.isEmpty {
            job.summary = "Installed \(job.finished.count) state\(job.finished.count == 1 ? "" : "s")."
        } else {
            job.summary = "Installed \(job.finished.count) of \(job.totalCount); \(job.failures.count) failed."
        }
        dataJob = job
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

    /// Adds trunked talkgroups to the open codeplug; returns how many were new.
    @discardableResult
    func addTalkgroups(_ talkgroups: [TrunkedTalkgroup], on system: TrunkedSystem) -> Int {
        let added = codeplug.addTalkgroups(talkgroups, on: system)
        if added > 0 { persistCodeplug() }
        return added
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

    /// Switches to a saved codeplug.
    func selectCodeplug(_ id: UUID) {
        if let found = codeplugs.first(where: { $0.id == id }) { codeplug = found }
    }

    func renameCodeplug(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        codeplug.name = trimmed
        codeplug.updatedAt = Date()
        persistCodeplug()
    }

    func setCodeplugTarget(_ target: RadioTarget) {
        codeplug.target = target
        codeplug.updatedAt = Date()
        persistCodeplug()
    }

    /// Deletes a codeplug from the database. If it was the open one, another takes its place (or a fresh empty one).
    func deleteCodeplug(_ id: UUID) {
        guard let userData else { return }
        Task {
            do {
                try await userData.deleteCodeplug(id: id)
                codeplugs = try await userData.codeplugs()
                if codeplug.id == id {
                    codeplug = codeplugs.first ?? Codeplug()
                    if codeplugs.isEmpty { persistCodeplug() }
                }
            } catch {
                lastError = "Could not delete the codeplug: \(error.localizedDescription)"
            }
        }
    }

    func duplicateCodeplug() {
        var copy = codeplug
        copy.id = UUID()
        copy.name = codeplug.name + " copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        codeplug = copy
        persistCodeplug()
    }

    func updateChannel(_ channel: CodeplugChannel) {
        codeplug.update(channel)
        persistCodeplug()
    }

    func moveChannels(from source: IndexSet, to destination: Int) {
        codeplug.moveChannels(from: source, to: destination)
        persistCodeplug()
    }

    func duplicateChannel(_ channel: CodeplugChannel) {
        codeplug.duplicate(channelID: channel.id)
        persistCodeplug()
    }

    func sortCodeplugByFrequency() {
        codeplug.sortByFrequency()
        persistCodeplug()
    }

    /// Applies a fix plan the operator previewed, if the codeplug is still what was previewed. Keeps the codeplug as it was so
    /// the fix can be undone.
    @discardableResult
    func applyCodeplugFix(_ plan: CodeplugFixPlan) -> Bool {
        guard let fixed = plan.applying(to: codeplug) else { return false }
        codeplugBeforeFix = codeplug
        codeplug = fixed
        persistCodeplug()
        return true
    }

    func undoCodeplugFix() {
        guard let before = codeplugBeforeFix, before.id == codeplug.id else { return }
        codeplug = before
        codeplugBeforeFix = nil
        persistCodeplug()
    }

    /// Adds the channels of a CHIRP CSV to the open codeplug. Returns what was read and what was skipped.
    func importCHIRP(csv: String) -> CHIRPCSVImporter.Result {
        let result = CHIRPCSVImporter.parse(csv)
        if !result.channels.isEmpty {
            codeplug.insert(result.channels)
            persistCodeplug()
        }
        return result
    }

    func tuneInScanner(frequencyHz: Double) {
        pendingScanFrequency = frequencyHz
    }
}

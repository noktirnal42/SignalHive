import SwiftUI
import SignalHiveCore

/// I/O for the Passes screen: the element and transmitter stores, the antennas in the user database, and running the
/// pass board off the main actor. The decisions (what is visible, how a pass is rated) live in SignalHiveCore.
@Observable @MainActor
final class SatellitesModel {
    var state = SatellitesState(observer: nil)
    var problems: [SatelliteProblem] = []
    var deepSpaceSkipped = 0
    var antennas: [AntennaProfile] = AntennaProfile.presets
    /// True until the owner saves an antenna: ratings then assume the NooElec kit and the screen says so.
    var usingPresetAntennas = true
    var elementsLine = "Elements not loaded yet"
    var transmittersLine = "Transmitter data not loaded yet"
    var isRefreshing = false
    var message: String?
    var selectedPassID: String?
    var showUTC = false
    var agingCount = 0
    /// True while the pass board is being computed off the main actor.
    var isComputing = false
    /// The start of the window the passes were computed for (the timeline's left edge).
    var windowStart = Date()

    private let elementStore: ElementStore
    private let transmitterStore: TransmitterStore
    private var database: UserDatabase?
    private var records: [SatelliteRecord] = []
    private var computeToken = 0

    init() {
        let base = AppModel.supportDirectory.appendingPathComponent("Satellites", isDirectory: true)
        elementStore = ElementStore(directory: base.appendingPathComponent("Elements", isDirectory: true))
        transmitterStore = TransmitterStore(directory: base.appendingPathComponent("Transmitters", isDirectory: true))
    }

    var selected: RatedPass? { state.all.first { $0.id == selectedPassID } }

    func setObserver(_ coordinate: GeoCoordinate?) {
        let observer = coordinate.map { Observer($0) }
        guard observer != state.observer else { return }
        state.observer = observer
        if observer == nil {
            state.phase = .needsLocation
            state.all = []
        } else if state.phase == .needsLocation {
            state.phase = records.isEmpty ? .loading : .ready
        }
        recompute()
    }

    func start(database: UserDatabase?, location: GeoCoordinate?) async {
        self.database = database
        state.observer = location.map { Observer($0) }
        state.phase = location == nil ? .needsLocation : .loading
        await loadAntennas()
        await refresh(force: false)
    }

    /// Loads (or, when allowed, fetches) elements and transmitters, then recomputes the passes.
    func refresh(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        message = nil
        var groups: [SatelliteCategory: [OrbitalElements]] = [:]
        var oldest: Date?
        var failure: String?
        var rejected = 0
        for category in SatelliteCategory.allCases {
            let load = await elementStore.elements(group: category.celestrakGroup, forceRefresh: force)
            groups[category] = load.elements
            rejected += load.rejectedRows
            if let fetched = load.fetchedAt { oldest = min(oldest ?? fetched, fetched) }
            switch load.source {
            case let .cacheAfterFailure(reason), let .none(reason): failure = failure ?? reason
            case .network, .cacheTooSoonToRefetch: break
            }
        }
        let imported = await elementStore.importedElements()
        let known = Set(groups.values.flatMap { $0.map(\.noradID) })
        groups[.amateur, default: []] += imported.filter { !known.contains($0.noradID) }

        let transmitters = await transmitterStore.load(forceRefresh: force)
        if case let .cacheAfterFailure(reason) = transmitters.source { failure = failure ?? reason }
        if case let .none(reason) = transmitters.source { failure = failure ?? reason }

        let overrides = (try? TransmitterOverrides.bundled()) ?? TransmitterOverrides(strengths: [:], notes: [:], verified: [])
        records = SatelliteDirectory.build(groups: groups, satellites: transmitters.satellites,
                                           transmitters: transmitters.transmitters, overrides: overrides)

        let timeFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)
        elementsLine = oldest.map { "Elements fetched \($0.formatted(timeFormat))" + (rejected > 0 ? ", \(rejected) unusable rows skipped" : "") }
            ?? "No elements on this Mac yet"
        transmittersLine = transmitters.fetchedAt.map { "Transmitters fetched \($0.formatted(timeFormat))" } ?? "No transmitter data on this Mac yet"

        if records.isEmpty {
            state.phase = failure.map { .offline($0) } ?? (state.observer == nil ? .needsLocation : .ready)
        } else if let failure {
            state.phase = .offline(failure)
        } else {
            state.phase = state.observer == nil ? .needsLocation : .ready
        }
        recompute()
    }

    func recompute() {
        guard let observer = state.observer, !records.isEmpty else {
            state.all = []
            problems = []
            isComputing = false
            return
        }
        isComputing = true
        computeToken += 1
        let token = computeToken
        let records = self.records, antennas = self.antennas, hours = state.filters.horizonHours
        Task.detached(priority: .userInitiated) {
            let now = Date()
            let result = PassBoard.compute(records: records, observer: observer, antennas: antennas, from: now,
                                           horizon: Double(hours) * 3600, minimumElevationDegrees: 5, now: now)
            await MainActor.run { [weak self] in
                guard let self, token == self.computeToken else { return }
                self.isComputing = false
                self.state.all = result.passes
                self.windowStart = now
                self.problems = result.problems
                self.deepSpaceSkipped = result.deepSpaceSkipped
                self.agingCount = records.filter {
                    switch ElementAge.confidence(epoch: $0.elements.epoch, now: now) {
                    case .aging, .stale: return true
                    default: return false
                    }
                }.count
                if let id = self.selectedPassID, !result.passes.contains(where: { $0.id == id }) { self.selectedPassID = nil }
            }
        }
    }

    func importElements(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let count = try await elementStore.importElements(text, named: url.lastPathComponent)
            message = "Imported \(count) element set\(count == 1 ? "" : "s") from \(url.lastPathComponent)."
            await refresh(force: false)
        } catch let error as ElementParser.ParseError {
            message = error.message
        } catch {
            message = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Antennas

    func loadAntennas() async {
        guard let database, let saved = try? await database.antennas() else { return }
        if saved.isEmpty {
            antennas = AntennaProfile.presets
            usingPresetAntennas = true
        } else {
            antennas = saved
            usingPresetAntennas = false
        }
    }

    func saveAntenna(_ antenna: AntennaProfile) async {
        guard let database else { return }
        // The first save also keeps the presets the owner had been rated against, so editing one antenna does not
        // silently drop the others.
        if usingPresetAntennas {
            for preset in AntennaProfile.presets where preset.id != antenna.id { try? await database.saveAntenna(preset) }
        }
        try? await database.saveAntenna(antenna)
        await loadAntennas()
        recompute()
    }

    func deleteAntenna(_ antenna: AntennaProfile) async {
        guard let database else { return }
        if usingPresetAntennas {
            for preset in AntennaProfile.presets { try? await database.saveAntenna(preset) }
        }
        try? await database.deleteAntenna(id: antenna.id)
        await loadAntennas()
        if (try? await database.antennas())?.isEmpty == true {
            // Deleting the last antenna must not bring the presets back by itself.
            antennas = []
            usingPresetAntennas = false
        }
        recompute()
    }
}

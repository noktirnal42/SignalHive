import Foundation

// MARK: - PackBrowseDataSource
//
// The real BrowseDataSource: reads whichever state packs are installed. A license that spans
// states lives in each state's pack (with that state's sites), so `detail` merges across packs.

public actor PackBrowseDataSource: BrowseDataSource {
    private let packs: PackStore
    private var opened: [String: (url: URL, store: FrequencyStore)] = [:]

    public init(packs: PackStore) {
        self.packs = packs
    }

    public func states() async -> [StateAvailability] {
        await packs.availability()
    }

    public func counties(in state: String) async throws -> [CountySummary] {
        try await store(for: state).counties()
    }

    public func licenses(in county: CountyID, filter: LicenseFilter) async throws -> [LicenseSummary] {
        try await store(for: county.stateCode).licenses(in: county, filter: filter)
    }

    public func detail(uid: Int64) async throws -> LicenseDetail {
        var merged: LicenseDetail?
        for store in try await allStores() {
            guard let found = try store.detail(uid: uid) else { continue }
            guard var current = merged else {
                merged = found
                continue
            }
            for site in found.sites where !current.sites.contains(where: { $0.id == site.id }) {
                current.sites.append(site)
            }
            for frequency in found.frequencies where !current.frequencies.contains(where: { $0.id == frequency.id }) {
                current.frequencies.append(frequency)
            }
            merged = current
        }
        guard var result = merged else { throw BrowseDataError.licenseNotFound(uid) }
        result.sites.sort { ($0.stateCode, $0.locationNumber) < ($1.stateCode, $1.locationNumber) }
        result.frequencies.sort { ($0.frequencyHz, $0.locationNumber) < ($1.frequencyHz, $1.locationNumber) }
        result.summary.frequencyCount = Set(result.frequencies.map(\.frequencyHz)).count
        result.summary.modeHints = Set(result.frequencies.flatMap(\.modeHints)).sorted()
        return result
    }

    public func search(_ query: String, scope: SearchScope) async throws -> [SearchHit] {
        let stores = try await allStores()
        let batches = try await withThrowingTaskGroup(of: [SearchHit].self) { group in
            for store in stores {
                group.addTask { try store.search(query, scope: scope) }
            }
            var all: [[SearchHit]] = []
            for try await batch in group { all.append(batch) }
            return all
        }
        var seen = Set<String>()
        return batches.flatMap { $0 }.filter { seen.insert($0.id).inserted }.prefix(200).map { $0 }
    }

    public func frequencies(near center: Coordinate, radiusKm: Double) async throws -> [NearbyFrequency] {
        let stores = try await allStores()
        let batches = try await withThrowingTaskGroup(of: [NearbyFrequency].self) { group in
            for store in stores {
                group.addTask { try store.nearby(center, radiusKm: radiusKm) }
            }
            var all: [[NearbyFrequency]] = []
            for try await batch in group { all.append(batch) }
            return all
        }
        var seen = Set<String>()
        return batches.flatMap { $0 }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.distanceKm < $1.distanceKm }
            .prefix(200).map { $0 }
    }

    // MARK: Opening packs

    private func store(for state: String) async throws -> FrequencyStore {
        guard let url = await packs.databaseURL(for: state) else { throw BrowseDataError.stateNotInstalled(state) }
        if let cached = opened[state], cached.url == url { return cached.store }
        let store = try FrequencyStore(path: url.path)
        opened[state] = (url, store)
        return store
    }

    private func allStores() async throws -> [FrequencyStore] {
        var stores: [FrequencyStore] = []
        for state in await packs.installedStates() {
            stores.append(try await store(for: state))
        }
        return stores
    }
}

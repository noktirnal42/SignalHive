import Foundation

// MARK: - BrowseDataSource
//
// The seam between data and UI. The real implementation reads installed state packs;
// `MockBrowseDataSource` serves canned data so views can be designed and previewed
// without any download.

public protocol BrowseDataSource: Sendable {
    func states() async -> [StateAvailability]
    func counties(in state: String) async throws -> [CountySummary]
    func licenses(in county: CountyID, filter: LicenseFilter) async throws -> [LicenseSummary]
    func detail(uid: Int64) async throws -> LicenseDetail
    func search(_ query: String, scope: SearchScope) async throws -> [SearchHit]
    func frequencies(near center: Coordinate, radiusKm: Double) async throws -> [NearbyFrequency]
}

public enum BrowseDataError: Error, LocalizedError, Equatable {
    case stateNotInstalled(String)
    case licenseNotFound(Int64)

    public var errorDescription: String? {
        switch self {
        case let .stateNotInstalled(state): return "The data for \(state) is not installed yet."
        case let .licenseNotFound(uid): return "License \(uid) was not found."
        }
    }
}

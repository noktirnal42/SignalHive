import Foundation

public struct PassFilters: Sendable, Equatable {
    public var categories: Set<SatelliteCategory>
    public var minimumGrade: PassGrade
    public var minimumElevationDegrees: Double
    /// How far ahead to predict: 24, 48 or 72 hours.
    public var horizonHours: Int
    /// Hide passes whose downlink SignalHive has no decoder for, or could never have (a SARSAT relay, telemetry in a
    /// format nobody here will build). A pass can still be heard; this keeps the list to ones that lead somewhere.
    public var decodableOnly: Bool

    public init(categories: Set<SatelliteCategory>, minimumGrade: PassGrade, minimumElevationDegrees: Double, horizonHours: Int,
                decodableOnly: Bool = true) {
        self.categories = categories
        self.minimumGrade = minimumGrade
        self.minimumElevationDegrees = minimumElevationDegrees
        self.horizonHours = horizonHours
        self.decodableOnly = decodableOnly
    }

    /// What the screen opens with: everything worth trying, so the list is short and every row is a real chance.
    public static let standard = PassFilters(categories: Set(SatelliteCategory.allCases), minimumGrade: .marginal,
                                             minimumElevationDegrees: 10, horizonHours: 48)
}

/// What the Passes screen shows and why, kept apart from the views so it is tested.
public struct SatellitesState: Sendable {
    public enum Phase: Sendable, Equatable {
        case needsLocation
        case loading
        case ready
        /// The network failed; passes from saved data are still listed, with the reason.
        case offline(String)
    }

    public var phase: Phase
    public var observer: Observer?
    public var all: [RatedPass]
    public var filters: PassFilters

    public init(observer: Observer?, all: [RatedPass] = [], filters: PassFilters = .standard) {
        self.observer = observer
        self.all = all
        self.filters = filters
        phase = observer == nil ? .needsLocation : .loading
    }

    public func visible() -> [RatedPass] {
        all.filter { item in
            filters.categories.contains(item.record.category)
                && item.rating.grade >= filters.minimumGrade
                && item.pass.maxElevationDegrees >= filters.minimumElevationDegrees
                && (!filters.decodableOnly || (item.transmitter.map { $0.kind.decoderStatus != .none } ?? false))
        }
    }

    /// "12 of 30 passes shown": the screen always says how many the filters are hiding.
    public var summary: String {
        guard !all.isEmpty else { return "No passes" }
        return "\(visible().count) of \(all.count) \(all.count == 1 ? "pass" : "passes") shown"
    }
}

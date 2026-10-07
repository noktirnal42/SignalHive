import Foundation

public enum SatelliteCategory: String, CaseIterable, Sendable {
    case weather, stations, amateur

    /// The CelesTrak GP group that lists this category.
    public var celestrakGroup: String { rawValue }

    public var title: String {
        switch self {
        case .weather: return "Weather"
        case .stations: return "Stations"
        case .amateur: return "Amateur"
        }
    }
}

public struct SatelliteRecord: Identifiable, Sendable {
    public var elements: OrbitalElements
    public var category: SatelliteCategory
    public var status: SatelliteStatus
    public var transmitters: [TransmitterInfo]
    public var strength: SignalStrengthClass
    public var note: String?

    public var id: Int { elements.noradID }

    /// The downlink a pass is judged on: active, inside what an RTL-SDR tunes (24 to 1766 MHz), and the one with the
    /// best decoder status. A downlink received on air by the owner ranks first; among equals the lowest frequency
    /// wins, so the choice never depends on feed order (SatNOGS cannot say which of several listed Meteor LRPT
    /// frequencies is on air, so the screen lists all of them and calls the choice a default).
    public var primaryTransmitter: TransmitterInfo? {
        transmitters
            .filter { $0.isActive && (24_000_000...1_766_000_000).contains($0.downlinkHz) }
            .min { lhs, rhs in
                let lhsKey = (lhs.verifiedOnAir == nil ? 1 : 0, lhs.kind.decoderStatus.rank, lhs.downlinkHz, lhs.id)
                let rhsKey = (rhs.verifiedOnAir == nil ? 1 : 0, rhs.kind.decoderStatus.rank, rhs.downlinkHz, rhs.id)
                return lhsKey < rhsKey
            }
    }
}

public enum SatelliteDirectory {
    /// Joins the element groups, SatNOGS status and transmitters, and the overrides into the satellites worth offering.
    /// A satellite in several groups appears once, in the first of weather, stations and amateur. Satellites SatNOGS
    /// lists as dead, re-entered or not yet launched are left out; ones it does not know stay (CelesTrak tracks them).
    public static func build(groups: [SatelliteCategory: [OrbitalElements]], satellites: [Int: SatelliteStatus],
                             transmitters: [TransmitterInfo], overrides: TransmitterOverrides) -> [SatelliteRecord] {
        let byID = Dictionary(grouping: transmitters, by: \.noradID)
        var seen = Set<Int>()
        var records: [SatelliteRecord] = []
        for category in SatelliteCategory.allCases {
            for elements in groups[category] ?? [] where seen.insert(elements.noradID).inserted {
                let status = satellites[elements.noradID] ?? .unknown
                guard status != .dead, status != .reentered, status != .future else { continue }

                var own = (byID[elements.noradID] ?? []).filter { !overrides.isSuppressed(noradID: $0.noradID, downlinkHz: $0.downlinkHz) }
                for verified in overrides.transmitters(for: elements.noradID) {
                    if let index = own.firstIndex(where: { $0.id == verified.id }) { own[index] = verified } else { own.append(verified) }
                }
                if category == .weather {
                    // SatNOGS labels many data downlinks "FM"; on a weather satellite that is not someone talking.
                    own = own.map { item in
                        var copy = item
                        if copy.kind == .fmVoice { copy.kind = .other }
                        return copy
                    }
                }
                records.append(SatelliteRecord(elements: elements, category: category, status: status, transmitters: own,
                                               strength: overrides.strength(for: elements.noradID),
                                               note: overrides.note(for: elements.noradID)))
            }
        }
        return records.sorted { ($0.elements.name, $0.elements.noradID) < ($1.elements.name, $1.elements.noradID) }
    }
}

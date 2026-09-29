import Foundation

// MARK: - MockBrowseDataSource
//
// Deterministic canned data for previews, screenshots and design work. Alabama is fully
// populated; other states cycle through every `PackStatus` so each UI state can be seen.

public struct MockBrowseDataSource: BrowseDataSource {

    public init() {}

    // MARK: Dataset

    private struct Entry: Sendable {
        var county: CountyID
        var detail: LicenseDetail
    }

    private static let counties: [(name: String, seat: String, lat: Double, lon: Double)] = [
        ("Baldwin", "Bay Minette", 30.8829, -87.7736), ("Calhoun", "Anniston", 33.6598, -85.8316),
        ("Coffee", "Enterprise", 31.3160, -85.8558), ("Etowah", "Gadsden", 34.0143, -86.0066),
        ("Jefferson", "Birmingham", 33.5207, -86.8025), ("Lee", "Opelika", 32.6454, -85.3783),
        ("Madison", "Huntsville", 34.7304, -86.5861), ("Mobile", "Mobile", 30.6954, -88.0399),
        ("Montgomery", "Montgomery", 32.3668, -86.3000), ("Morgan", "Decatur", 34.6059, -86.9833),
        ("Shelby", "Columbiana", 33.1782, -86.6064), ("Tuscaloosa", "Tuscaloosa", 33.2098, -87.5692),
    ]

    private static let entries: [Entry] = {
        var result: [Entry] = []
        for (index, county) in counties.enumerated() {
            let countyID = CountyID(stateCode: "AL", id: "AL:\(county.name.uppercased())")
            let offset = Double(index)
            let templates: [(name: String, service: String, freqs: [(Double, [ModeHint], Double, String)])] = [
                ("\(county.name) County Sheriff's Office", "PW", [
                    (155.4750 + offset * 0.015, [.analogFM], 11_200, "MO"),
                    (856.0125 + offset * 0.025, [.analogFM, .digitalP25], 8_100, "FB2"),
                ]),
                ("City of \(county.seat) Fire Department", "PW", [
                    (154.2800 + offset * 0.010, [.analogFM], 11_200, "FB2"),
                ]),
                ("\(county.seat) Emergency Medical Services", "PW", [
                    (155.3400 + offset * 0.010, [.analogFM], 11_200, "FB2"),
                    (858.4875 + offset * 0.025, [.digitalP25], 8_100, "FB2"),
                ]),
                ("\(county.seat) Utilities Board", "IG", [
                    (451.6125 + offset * 0.0125, [.analogFM], 11_200, "FB"),
                ]),
                ("\(county.name) County Board of Education", "IG", [
                    (464.5500 + offset * 0.0125, [.analogFM], 11_200, "FB"),
                    (469.5500 + offset * 0.0125, [.analogFM], 11_200, "MO"),
                ]),
            ]
            for (position, template) in templates.enumerated() {
                let uid = Int64(10_000 + index * 10 + position)
                let letter = String(UnicodeScalar(UInt8(65 + index)))
                let callSign = String(format: "WQ%@%03d", letter, 100 + position * 7 + index)
                let frequencies = template.freqs.map { frequency, hints, bandwidth, stationClass in
                    FrequencyRecord(uid: uid, locationNumber: 1, frequencyHz: (frequency * 1_000_000).rounded(),
                                    classStationCode: stationClass, powerW: 35, modeHints: hints, bandwidthHz: bandwidth)
                }
                let site = SiteRecord(
                    uid: uid, locationNumber: 1, city: county.seat.uppercased(), countyName: "\(county.name) County",
                    stateCode: "AL", latitude: county.lat + Double(position) * 0.01, longitude: county.lon + Double(position) * 0.01
                )
                let summary = LicenseSummary(
                    uid: uid, callSign: callSign, licenseeName: template.name.uppercased(), serviceCode: template.service,
                    serviceName: RadioServiceCatalog.name(for: template.service), city: county.seat.uppercased(),
                    frequencyCount: frequencies.count, modeHints: Set(frequencies.flatMap(\.modeHints)).sorted()
                )
                result.append(Entry(
                    county: countyID,
                    detail: LicenseDetail(summary: summary, grantDate: "03/14/2019", expiredDate: "03/14/2029",
                                          sites: [site], frequencies: frequencies)
                ))
            }
        }
        return result
    }()

    // MARK: BrowseDataSource

    public func states() async -> [StateAvailability] {
        USStateCatalog.states.enumerated().map { index, state in
            let status: PackStatus
            switch state.code {
            case "AL": status = .installed(snapshot: "2026-09-25")
            case "GA": status = .downloading(progress: 0.42)
            case "TX": status = .failed(reason: "Could not reach the data server. Check your connection and try again.")
            case "FL": status = .notInstalled(sizeBytes: 1_240_000)
            default: status = .notInstalled(sizeBytes: Int64(400_000 + index * 37_000))
            }
            return StateAvailability(code: state.code, name: state.name, status: status)
        }
    }

    public func counties(in state: String) async throws -> [CountySummary] {
        guard state == "AL" else { throw BrowseDataError.stateNotInstalled(state) }
        return Self.counties.map { county in
            let id = CountyID(stateCode: "AL", id: "AL:\(county.name.uppercased())")
            return CountySummary(id: id, name: "\(county.name) County",
                                 licenseCount: Self.entries.filter { $0.county == id }.count)
        }
    }

    public func licenses(in county: CountyID, filter: LicenseFilter) async throws -> [LicenseSummary] {
        guard county.stateCode == "AL" else { throw BrowseDataError.stateNotInstalled(county.stateCode) }
        let text = filter.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return Self.entries
            .filter { $0.county == county }
            .map(\.detail.summary)
            .filter { filter.serviceCodes.isEmpty || filter.serviceCodes.contains($0.serviceCode) }
            .filter { text.isEmpty || $0.licenseeName.lowercased().contains(text) || $0.callSign.lowercased().contains(text) }
            .sorted { $0.licenseeName < $1.licenseeName }
    }

    public func detail(uid: Int64) async throws -> LicenseDetail {
        guard let entry = Self.entries.first(where: { $0.detail.summary.uid == uid }) else {
            throw BrowseDataError.licenseNotFound(uid)
        }
        return entry.detail
    }

    public func search(_ query: String, scope: SearchScope) async throws -> [SearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return [] }
        var hits: [SearchHit] = []
        let numeric = Double(text)

        if scope == .frequency || (scope == .all && numeric != nil), let mhz = numeric {
            let hz = mhz * 1_000_000
            for entry in Self.entries {
                for frequency in entry.detail.frequencies where abs(frequency.frequencyHz - hz) <= 12_500 {
                    hits.append(SearchHit(kind: .frequency, uid: frequency.uid, title: frequency.displayMHz,
                                          subtitle: "\(entry.detail.summary.licenseeName) · \(entry.detail.summary.city)",
                                          frequencyHz: frequency.frequencyHz))
                }
            }
        }
        if scope != .frequency {
            for entry in Self.entries {
                let summary = entry.detail.summary
                let byCall = summary.callSign.lowercased().contains(text)
                let byName = summary.licenseeName.lowercased().contains(text)
                let matches: Bool
                switch scope {
                case .callSign: matches = byCall
                case .licensee: matches = byName
                default: matches = byCall || byName
                }
                if matches {
                    hits.append(SearchHit(kind: .license, uid: summary.uid, title: summary.licenseeName,
                                          subtitle: "\(summary.callSign) · \(summary.serviceName) · \(summary.city)"))
                }
            }
        }
        return hits
    }

    public func frequencies(near center: Coordinate, radiusKm: Double) async throws -> [NearbyFrequency] {
        var results: [NearbyFrequency] = []
        for entry in Self.entries {
            for site in entry.detail.sites {
                guard let latitude = site.latitude, let longitude = site.longitude else { continue }
                let distance = FrequencyStore.haversineKm(center.latitude, center.longitude, latitude, longitude)
                guard distance <= radiusKm else { continue }
                for frequency in entry.detail.frequencies where frequency.locationNumber == site.locationNumber {
                    results.append(NearbyFrequency(frequency: frequency, callSign: entry.detail.summary.callSign,
                                                   city: site.city, distanceKm: distance))
                }
            }
        }
        return results.sorted { $0.distanceKm < $1.distanceKm }
    }
}

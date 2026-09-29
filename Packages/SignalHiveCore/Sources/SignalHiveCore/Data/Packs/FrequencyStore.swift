import Foundation
import GRDB

// MARK: - FrequencyStore
//
// Read-only queries over one state's pack. Every method throws on failure so callers can
// show the reason; nothing here swallows an error.

public final class FrequencyStore: Sendable {
    public let stateCode: String
    public let snapshotDate: String
    private let queue: DatabaseQueue

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: path, configuration: configuration)
        } catch {
            throw PackStoreError.corrupt("cannot open the file (\(error.localizedDescription))")
        }
        let meta: [String: String]
        do {
            meta = try queue.read { db in
                var values: [String: String] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT key, value FROM meta") {
                    let key: String = row["key"]
                    let value: String = row["value"]
                    values[key] = value
                }
                return values
            }
        } catch {
            throw PackStoreError.corrupt("not a SignalHive data pack")
        }
        let version = Int(meta["schemaVersion"] ?? "") ?? 0
        guard version >= 1 else { throw PackStoreError.corrupt("missing schema version") }
        guard version <= packSchemaVersion else { throw PackStoreError.schemaTooNew(version) }
        self.queue = queue
        self.stateCode = meta["stateCode"] ?? ""
        self.snapshotDate = meta["fccSnapshotDate"] ?? ""
    }

    // MARK: Counties

    public func counties() throws -> [CountySummary] {
        try queue.read { db in
            var result = try Row.fetchAll(
                db, sql: "SELECT countyId, name, licenseCount FROM counties ORDER BY name COLLATE NOCASE"
            ).map { row -> CountySummary in
                let id: String = row["countyId"]
                let name: String = row["name"]
                let count: Int = row["licenseCount"]
                return CountySummary(id: CountyID(stateCode: stateCode, id: id), name: name, licenseCount: count)
            }
            let unknown = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT uid) FROM sites WHERE countyId IS NULL") ?? 0
            if unknown > 0 {
                result.append(CountySummary(id: CountyID(stateCode: stateCode, id: "\(stateCode):?"),
                                            name: "County unknown", licenseCount: unknown))
            }
            return result
        }
    }

    // MARK: Licenses

    public func licenses(in county: CountyID, filter: LicenseFilter, limit: Int = 1000) throws -> [LicenseSummary] {
        try queue.read { db in
            let siteCondition = county.isUnknownBucket ? "s.countyId IS NULL" : "s.countyId = ?"
            var arguments: [DatabaseValueConvertible] = []
            var perLicenseArguments: [DatabaseValueConvertible] = []
            if !county.isUnknownBucket {
                perLicenseArguments.append(county.id)
            }

            var sql = """
            SELECT l.uid, l.callSign, l.licenseeName, l.serviceCode, l.city,
                   (SELECT COUNT(DISTINCT f.frequencyHz) FROM frequencies f
                     JOIN sites s ON s.uid = f.uid AND s.locationNumber = f.locationNumber
                     WHERE f.uid = l.uid AND \(siteCondition)) AS frequencyCount,
                   (SELECT group_concat(f.modeHints) FROM frequencies f
                     JOIN sites s ON s.uid = f.uid AND s.locationNumber = f.locationNumber
                     WHERE f.uid = l.uid AND \(siteCondition)) AS hints
            FROM licenses l
            WHERE l.uid IN (SELECT s.uid FROM sites s WHERE \(siteCondition))
            """
            // The county condition appears three times; supply its argument for each.
            arguments.append(contentsOf: perLicenseArguments)
            arguments.append(contentsOf: perLicenseArguments)
            arguments.append(contentsOf: perLicenseArguments)

            if !filter.serviceCodes.isEmpty {
                sql += " AND l.serviceCode IN (\(Array(repeating: "?", count: filter.serviceCodes.count).joined(separator: ",")))"
                arguments.append(contentsOf: filter.serviceCodes.sorted())
            }
            if let text = filter.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                sql += " AND (l.callSign LIKE ? ESCAPE '\\' OR l.licenseeName LIKE ? ESCAPE '\\')"
                let like = "%" + Self.escapeLike(text) + "%"
                arguments.append(like)
                arguments.append(like)
            }
            sql += " ORDER BY l.licenseeName COLLATE NOCASE, l.callSign LIMIT \(limit)"

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                Self.summary(from: row, frequencyCount: row["frequencyCount"], hints: row["hints"])
            }
        }
    }

    public func detail(uid: Int64) throws -> LicenseDetail? {
        try queue.read { db in
            guard let license = try Row.fetchOne(db, sql: "SELECT * FROM licenses WHERE uid = ?", arguments: [uid]) else {
                return nil
            }
            let sites = try Row.fetchAll(db, sql: """
                SELECT s.*, c.name AS countyName FROM sites s
                LEFT JOIN counties c ON c.countyId = s.countyId
                WHERE s.uid = ? ORDER BY s.locationNumber
                """, arguments: [uid]).map { row in
                SiteRecord(uid: row["uid"], locationNumber: row["locationNumber"], city: row["city"],
                           countyName: row["countyName"], stateCode: row["stateCode"],
                           latitude: row["latitude"], longitude: row["longitude"])
            }
            let frequencies = try Row.fetchAll(
                db, sql: "SELECT * FROM frequencies WHERE uid = ? ORDER BY frequencyHz, locationNumber", arguments: [uid]
            ).map(Self.frequency(from:))

            let hints = Set(frequencies.flatMap(\.modeHints))
            let summary = Self.summary(
                from: license,
                frequencyCount: Set(frequencies.map(\.frequencyHz)).count,
                hints: hints.isEmpty ? nil : hints.map(\.rawValue).joined(separator: ",")
            )
            return LicenseDetail(summary: summary, grantDate: license["grantDate"], expiredDate: license["expiredDate"],
                                 sites: sites, frequencies: frequencies)
        }
    }

    // MARK: Search

    public func search(_ query: String, scope: SearchScope, limit: Int = 200) throws -> [SearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var hits: [SearchHit] = []

        let numeric = Double(text)
        if scope == .frequency || (scope == .all && numeric != nil) {
            if let mhz = numeric {
                hits += try searchFrequency(mhz: mhz, limit: limit)
            }
        }
        if scope != .frequency, let match = Self.ftsQuery(text, scope: scope) {
            hits += try searchLicenses(match: match, limit: limit)
        }
        return hits
    }

    private func searchFrequency(mhz: Double, limit: Int) throws -> [SearchHit] {
        let hz = mhz * 1_000_000
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.uid, f.frequencyHz, l.callSign, l.licenseeName, COALESCE(s.city, '') AS city
                FROM frequencies f
                JOIN licenses l ON l.uid = f.uid
                LEFT JOIN sites s ON s.uid = f.uid AND s.locationNumber = f.locationNumber
                WHERE f.frequencyHz BETWEEN ? AND ?
                ORDER BY f.frequencyHz LIMIT ?
                """, arguments: [hz - 12_500, hz + 12_500, limit]).map { row in
                let uid: Int64 = row["uid"]
                let frequency: Double = row["frequencyHz"]
                let callSign: String = row["callSign"]
                let name: String = row["licenseeName"]
                let city: String = row["city"]
                return SearchHit(kind: .frequency, uid: uid,
                                 title: FrequencyRecord(uid: uid, locationNumber: 0, frequencyHz: frequency).displayMHz,
                                 subtitle: [name.isEmpty ? callSign : name, city].filter { !$0.isEmpty }.joined(separator: " · "),
                                 frequencyHz: frequency)
            }
        }
    }

    private func searchLicenses(match: String, limit: Int) throws -> [SearchHit] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.uid, l.callSign, l.licenseeName, l.serviceCode, l.city
                FROM licenses_fts JOIN licenses l ON l.uid = licenses_fts.rowid
                WHERE licenses_fts MATCH ?
                ORDER BY rank LIMIT ?
                """, arguments: [match, limit]).map { row in
                let uid: Int64 = row["uid"]
                let callSign: String = row["callSign"]
                let name: String = row["licenseeName"]
                let service: String = row["serviceCode"]
                let city: String = row["city"]
                return SearchHit(kind: .license, uid: uid, title: name.isEmpty ? callSign : name,
                                 subtitle: [callSign, RadioServiceCatalog.name(for: service), city]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
            }
        }
    }

    // MARK: Nearby

    public func nearby(_ center: Coordinate, radiusKm: Double, limit: Int = 200) throws -> [NearbyFrequency] {
        let latDelta = radiusKm / 111.0
        let lonDelta = radiusKm / max(1.0, 111.0 * cos(center.latitude * .pi / 180.0))
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.*, l.callSign AS callSign, s.city AS city, s.latitude AS latitude, s.longitude AS longitude
                FROM sites s
                JOIN frequencies f ON f.uid = s.uid AND f.locationNumber = s.locationNumber
                JOIN licenses l ON l.uid = s.uid
                WHERE s.latitude BETWEEN ? AND ? AND s.longitude BETWEEN ? AND ?
                LIMIT ?
                """, arguments: [center.latitude - latDelta, center.latitude + latDelta,
                                 center.longitude - lonDelta, center.longitude + lonDelta, limit * 4])
        }
        var results: [NearbyFrequency] = []
        for row in rows {
            let latitude: Double = row["latitude"]
            let longitude: Double = row["longitude"]
            let distance = Self.haversineKm(center.latitude, center.longitude, latitude, longitude)
            guard distance <= radiusKm else { continue }
            results.append(NearbyFrequency(frequency: Self.frequency(from: row), callSign: row["callSign"],
                                           city: row["city"], distanceKm: distance))
        }
        results.sort { $0.distanceKm < $1.distanceKm }
        return Array(results.prefix(limit))
    }

    // MARK: Helpers

    private static func summary(from row: Row, frequencyCount: Int?, hints: String?) -> LicenseSummary {
        let service: String = row["serviceCode"]
        return LicenseSummary(
            uid: row["uid"], callSign: row["callSign"], licenseeName: row["licenseeName"],
            serviceCode: service, serviceName: RadioServiceCatalog.name(for: service), city: row["city"],
            frequencyCount: frequencyCount ?? 0, modeHints: parseHints(hints)
        )
    }

    private static func frequency(from row: Row) -> FrequencyRecord {
        FrequencyRecord(
            uid: row["uid"], locationNumber: row["locationNumber"], frequencyHz: row["frequencyHz"],
            upperBandHz: row["upperBandHz"], classStationCode: row["classStationCode"], powerW: row["powerW"],
            modeHints: parseHints(row["modeHints"]), bandwidthHz: row["bandwidthHz"]
        )
    }

    /// Distinct hints in enum order; `unknown` is dropped when anything better is known.
    static func parseHints(_ joined: String?) -> [ModeHint] {
        guard let joined else { return [] }
        let all = Set(joined.split(separator: ",").compactMap { ModeHint(rawValue: String($0)) })
        let known = all.subtracting([.unknown])
        return (known.isEmpty ? all : known).sorted()
    }

    /// Builds a safe FTS5 query: every token is quoted and prefix-matched, so user text can never
    /// be interpreted as FTS syntax. Returns nil when nothing searchable remains.
    static func ftsQuery(_ text: String, scope: SearchScope) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
        guard !tokens.isEmpty else { return nil }
        let terms = tokens.joined(separator: " ")
        switch scope {
        case .callSign: return "callSign : (\(terms))"
        case .licensee: return "licenseeName : (\(terms))"
        default: return terms
        }
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

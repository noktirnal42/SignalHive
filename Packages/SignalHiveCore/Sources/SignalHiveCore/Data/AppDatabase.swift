import Foundation
import GRDB

// MARK: - SignalHive database (GRDB)

public actor AppDatabase {
    private let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    public static func open(at path: String) async throws -> AppDatabase {
        let pool = try DatabasePool(path: path)
        let db = AppDatabase(dbPool: pool)
        try await db.migrate()
        return db
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SignalHive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SignalHive.sqlite")
    }

    // MARK: Migrations

    private func migrate() async throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "states", options: .ifNotExists) { t in
                t.column("code", .text).primaryKey()
                t.column("name", .text).notNull()
            }
            try db.create(table: "counties", options: .ifNotExists) { t in
                t.column("stateCode", .text).notNull()
                t.column("county", .text).notNull()
                t.primaryKey(["stateCode", "county"])
            }
            try db.create(table: "entities", options: .ifNotExists) { t in
                t.column("uid", .integer).primaryKey()
                t.column("callSign", .text).notNull().indexed()
                t.column("entityType", .text)
                t.column("name", .text).indexed()
                t.column("city", .text)
                t.column("state", .text).indexed()
                t.column("zipCode", .text)
            }
            try db.create(table: "licenses", options: .ifNotExists) { t in
                t.column("uid", .integer).primaryKey()
                t.column("callSign", .text).notNull()
                t.column("licenseStatus", .text)
                t.column("radioServiceCode", .text).indexed()
                t.column("grantDate", .text)
                t.column("expiredDate", .text)
            }
            try db.create(table: "frequencies", options: .ifNotExists) { t in
                t.column("uid", .integer).notNull().indexed()
                t.column("callSign", .text).notNull()
                t.column("locationNumber", .integer).notNull()
                t.column("frequencyHz", .double).notNull().indexed()
                t.column("upperBandHz", .double)
                t.column("isCarrier", .boolean)
                t.column("classStationCode", .text)
                t.column("powerOutput", .text)
                t.column("status", .text)
            }
            try db.create(table: "locations", options: .ifNotExists) { t in
                t.column("uid", .integer).notNull().indexed()
                t.column("locationNumber", .integer).notNull()
                t.column("city", .text).indexed()
                t.column("county", .text).indexed()
                t.column("state", .text).indexed()
                t.column("latitude", .double)
                t.column("longitude", .double)
            }
            try db.create(table: "emissions", options: .ifNotExists) { t in
                t.column("uid", .integer).notNull()
                t.column("frequencyHz", .double).notNull()
                t.column("emissionCode", .text)
            }
            try db.create(table: "comments", options: .ifNotExists) { t in
                t.column("uid", .integer).notNull()
                t.column("callSign", .text)
                t.column("descriptionText", .text)
            }
            try db.create(table: "codeplugs", options: .ifNotExists) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("target", .text).notNull()
                t.column("channelsJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "import_state", options: .ifNotExists) { t in
                t.column("service", .text).primaryKey()
                t.column("importedAt", .datetime).notNull()
                t.column("recordCount", .integer).notNull()
                t.column("sourceURL", .text).notNull()
            }
        }

        try await migrator.migrate(dbPool)
    }

    // MARK: Seed states

    public func seedStatesIfNeeded() async throws {
        let count = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM states") ?? 0
        }
        guard count == 0 else { return }
        _ = try await dbPool.write { db in
            for s in USStateCatalog.states {
                try USState(code: s.code, name: s.name).insert(db)
            }
        }
    }

    // MARK: Import writes

    public struct ImportBatchReport: Sendable {
        public var imported: Int
    }

    public func writeBatch(_ batch: ULSRecordBatch, service: ULSService, sourceURL: URL) async throws {
        _ = try await dbPool.write { db in
            for e in batch.entities {
                var row = e
                try row.insert(db, onConflict: .ignore)
            }
            for l in batch.licenses {
                var row = l
                try row.insert(db, onConflict: .ignore)
            }
            for f in batch.frequencies {
                var row = f
                try row.insert(db, onConflict: .ignore)
            }
            for loc in batch.locations {
                var row = loc
                try row.insert(db, onConflict: .ignore)
            }
            for em in batch.emissions {
                var row = em
                try row.insert(db)
            }
            for c in batch.comments {
                var row = c
                try row.insert(db)
            }
        }
        try await recordImportState(service: service, sourceURL: sourceURL, count: batch.count)
    }

    private func recordImportState(service: ULSService, sourceURL: URL, count: Int) async throws {
        _ = try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO import_state (service, importedAt, recordCount, sourceURL)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(service) DO UPDATE SET importedAt = ?, recordCount = ?, sourceURL = ?
                """,
                arguments: [service.rawValue, Date(), count, sourceURL.absoluteString, Date(), count, sourceURL.absoluteString]
            )
        }
    }

    public func importState(for service: ULSService) async throws -> (date: Date, count: Int, url: String)? {
        try await dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT importedAt, recordCount, sourceURL FROM import_state WHERE service = ?",
                arguments: [service.rawValue]
            )
            guard let row else { return nil }
            return (row["importedAt"] ?? Date(), row["recordCount"] ?? 0, row["sourceURL"] ?? "")
        }
    }

    // MARK: Browse queries

    public func allStates() async throws -> [USState] {
        try await dbPool.read { db in
            try USState.order(Column("name").asc).fetchAll(db)
        }
    }

    public func counties(in stateCode: String) async throws -> [USCounty] {
        try await dbPool.read { db in
            try USCounty
                .filter(Column("stateCode") == stateCode)
                .order(Column("county").asc)
                .fetchAll(db)
        }
    }

    public func countiesWithLicenseCounts(in stateCode: String) async throws -> [(county: USCounty, count: Int)] {
        let rows = try await dbPool.read { db -> [(String, Int)] in
            let fetched = try Row.fetchAll(
                db,
                sql: """
                SELECT l.county AS county, COUNT(DISTINCT lic.uid) AS licenseCount
                FROM locations l
                JOIN licenses lic ON lic.uid = l.uid AND lic.licenseStatus = 'A'
                LEFT JOIN frequencies f ON f.uid = l.uid AND f.locationNumber = l.locationNumber
                WHERE l.state = ? AND l.county != ''
                GROUP BY l.county
                ORDER BY l.county ASC
                """,
                arguments: [stateCode]
            )
            return fetched.map { ($0["county"] ?? "", $0["licenseCount"] ?? 0) }
        }
        return rows.map {
            (USCounty(stateCode: stateCode, county: $0.0), $0.1)
        }
    }

    public struct LicenseListing: Sendable, Identifiable, Hashable {
        public var uid: Int64
        public var callSign: String
        public var licenseeName: String
        public var serviceName: String
        public var statusName: String
        public var city: String
        public var county: String
        public var frequencyCount: Int
        public var id: Int64 { uid }
    }

    public func licenses(in stateCode: String, county: String?, service: String?, limit: Int = 500) async throws -> [LicenseListing] {
        try await dbPool.read { db in
            var sql = """
            SELECT lic.uid AS uid, lic.callSign AS callSign,
                   COALESCE(e.name, '') AS licenseeName,
                   COALESCE(lic.radioServiceCode, '') AS serviceCode,
                   COALESCE(lic.licenseStatus, 'A') AS statusCode,
                   COALESCE(MAX(l.city), '') AS city,
                   COALESCE(MAX(l.county), '') AS county,
                   COUNT(DISTINCT f.frequencyHz) AS frequencyCount
            FROM licenses lic
            LEFT JOIN entities e ON e.uid = lic.uid
            LEFT JOIN locations l ON l.uid = lic.uid
            LEFT JOIN frequencies f ON f.uid = lic.uid AND f.locationNumber = l.locationNumber
            WHERE l.state = ?
            """
            var args: [DatabaseValueConvertible] = [stateCode]
            if let county, !county.isEmpty {
                sql += " AND l.county = ?"
                args.append(county)
            }
            if let service, !service.isEmpty {
                sql += " AND lic.radioServiceCode = ?"
                args.append(service)
            }
            sql += " GROUP BY lic.uid, lic.callSign, e.name, lic.radioServiceCode, lic.licenseStatus"
            sql += " ORDER BY licenseeName ASC, callSign ASC LIMIT \(limit)"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map {
                LicenseListing(
                    uid: $0["uid"] ?? 0,
                    callSign: $0["callSign"] ?? "",
                    licenseeName: $0["licenseeName"] ?? "",
                    serviceName: RadioServiceCatalog.name(for: $0["serviceCode"] ?? ""),
                    statusName: LicenseStatusCatalog.name(for: $0["statusCode"] ?? ""),
                    city: $0["city"] ?? "",
                    county: $0["county"] ?? "",
                    frequencyCount: $0["frequencyCount"] ?? 0
                )
            }
        }
    }

    public struct LicenseDetail: Sendable {
        public var license: ULSLicense?
        public var entity: ULSEntity?
        public var frequencies: [ULSFrequency]
        public var locations: [ULSLocation]
        public var emissions: [ULSEmission]
        public var comments: [ULSComment]
    }

    public func licenseDetail(uid: Int64) async throws -> LicenseDetail {
        try await dbPool.read { db in
            LicenseDetail(
                license: try ULSLicense.fetchOne(db, key: uid),
                entity: try ULSEntity.fetchOne(db, key: uid),
                frequencies: try ULSFrequency.filter(Column("uid") == uid).order(Column("frequencyHz").asc).fetchAll(db),
                locations: try ULSLocation.filter(Column("uid") == uid).order(Column("locationNumber").asc).fetchAll(db),
                emissions: try ULSEmission.filter(Column("uid") == uid).fetchAll(db),
                comments: try ULSComment.filter(Column("uid") == uid).fetchAll(db)
            )
        }
    }

    public struct SearchResult: Sendable, Identifiable, Hashable {
        public var kind: String
        public var uid: Int64?
        public var callSign: String
        public var title: String
        public var subtitle: String
        public var frequencyHz: Double?
        public var id: String { "\(kind)-\(uid ?? -1)-\(title)" }
    }

    public func search(query: String, service: String?, state: String?, limit: Int = 200) async throws -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        var results: [SearchResult] = []

        struct LicenseHit: Sendable {
            var uid: Int64
            var callSign: String
            var name: String
            var serviceCode: String
            var statusCode: String
        }

        // Call sign / licensee name matches
        let like = "%\(q)%"
        let licenses = try await dbPool.read { db -> [LicenseHit] in
            var sql = """
            SELECT DISTINCT lic.uid AS uid, lic.callSign AS callSign,
                   COALESCE(e.name, '') AS name,
                   COALESCE(lic.radioServiceCode, '') AS serviceCode,
                   COALESCE(lic.licenseStatus, 'A') AS statusCode
            FROM licenses lic
            LEFT JOIN entities e ON e.uid = lic.uid
            WHERE (lic.callSign LIKE ? OR e.name LIKE ?)
            """
            var args: [DatabaseValueConvertible] = [like, like]
            if let service, !service.isEmpty {
                sql += " AND lic.radioServiceCode = ?"
                args.append(service)
            }
            if let state, !state.isEmpty {
                sql += " AND EXISTS (SELECT 1 FROM locations l WHERE l.uid = lic.uid AND l.state = ?)"
                args.append(state)
            }
            sql += " LIMIT \(limit)"
            let fetched = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return fetched.map {
                LicenseHit(
                    uid: $0["uid"] ?? 0,
                    callSign: $0["callSign"] ?? "",
                    name: $0["name"] ?? "",
                    serviceCode: $0["serviceCode"] ?? "",
                    statusCode: $0["statusCode"] ?? ""
                )
            }
        }

        for hit in licenses {
            results.append(SearchResult(
                kind: "license",
                uid: hit.uid,
                callSign: hit.callSign,
                title: hit.name.isEmpty ? hit.callSign : hit.name,
                subtitle: "\(hit.callSign) · \(RadioServiceCatalog.name(for: hit.serviceCode)) · \(LicenseStatusCatalog.name(for: hit.statusCode))",
                frequencyHz: nil
            ))
        }

        // Frequency match (MHz or Hz)
        if let mhz = Double(q) {
            struct FreqHit: Sendable {
                var uid: Int64
                var frequencyHz: Double
                var callSign: String
                var city: String
                var county: String
                var state: String
            }
            let hz = mhz * 1_000_000
            let freqs = try await dbPool.read { db -> [FreqHit] in
                let fetched = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT f.uid AS uid, f.frequencyHz AS frequencyHz, f.callSign AS callSign,
                           COALESCE(l.city, '') AS city, COALESCE(l.county, '') AS county, COALESCE(l.state, '') AS state
                    FROM frequencies f
                    LEFT JOIN locations l ON l.uid = f.uid AND l.locationNumber = f.locationNumber
                    WHERE f.frequencyHz BETWEEN ? AND ?
                    ORDER BY f.frequencyHz ASC
                    LIMIT 100
                    """,
                    arguments: [hz - 12_500, hz + 12_500]
                )
                return fetched.map {
                    FreqHit(
                        uid: $0["uid"] ?? 0,
                        frequencyHz: $0["frequencyHz"] ?? 0,
                        callSign: $0["callSign"] ?? "",
                        city: $0["city"] ?? "",
                        county: $0["county"] ?? "",
                        state: $0["state"] ?? ""
                    )
                }
            }
            for hit in freqs {
                let f = ULSFrequency(
                    uid: hit.uid,
                    callSign: hit.callSign,
                    locationNumber: 0,
                    frequencyHz: hit.frequencyHz,
                    upperBandHz: 0,
                    isCarrier: false,
                    classStationCode: "",
                    powerOutput: "",
                    status: ""
                )
                let loc = [hit.city, hit.county, hit.state]
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                results.append(SearchResult(
                    kind: "frequency",
                    uid: f.uid,
                    callSign: f.callSign,
                    title: f.displayMHz,
                    subtitle: "\(f.callSign)\(loc.isEmpty ? "" : " · \(loc)")",
                    frequencyHz: f.frequencyHz
                ))
            }
        }

        return results
    }

    public struct NearMeResult: Sendable, Identifiable, Hashable {
        public var frequency: ULSFrequency
        public var distanceKm: Double
        public var city: String
        public var county: String
        public var id: String { frequency.id }
    }

    public func frequencies(nearLatitude lat: Double, longitude lon: Double, radiusKm: Double, limit: Int = 200) async throws -> [NearMeResult] {
        struct NearHit: Sendable {
            var uid: Int64
            var frequencyHz: Double
            var callSign: String
            var latitude: Double
            var longitude: Double
            var city: String
            var county: String
        }

        // Bounding box prefilter (~cos(lat) lon scaling), then exact distance.
        let latDelta = radiusKm / 111.0
        let lonDelta = radiusKm / max(1.0, 111.0 * cos(lat * .pi / 180.0))
        let rows = try await dbPool.read { db -> [NearHit] in
            let fetched = try Row.fetchAll(
                db,
                sql: """
                SELECT f.uid AS uid, f.frequencyHz AS frequencyHz, f.callSign AS callSign,
                       l.latitude AS latitude, l.longitude AS longitude,
                       COALESCE(l.city, '') AS city, COALESCE(l.county, '') AS county
                FROM locations l
                JOIN frequencies f ON f.uid = l.uid AND f.locationNumber = l.locationNumber
                WHERE l.latitude BETWEEN ? AND ? AND l.longitude BETWEEN ? AND ?
                LIMIT ?
                """,
                arguments: [lat - latDelta, lat + latDelta, lon - lonDelta, lon + lonDelta, limit * 4]
            )
            return fetched.map {
                NearHit(
                    uid: $0["uid"] ?? 0,
                    frequencyHz: $0["frequencyHz"] ?? 0,
                    callSign: $0["callSign"] ?? "",
                    latitude: $0["latitude"] ?? 0,
                    longitude: $0["longitude"] ?? 0,
                    city: $0["city"] ?? "",
                    county: $0["county"] ?? ""
                )
            }
        }

        var out: [NearMeResult] = []
        for hit in rows {
            let d = Self.haversineKm(lat1: lat, lon1: lon, lat2: hit.latitude, lon2: hit.longitude)
            guard d <= radiusKm else { continue }
            let f = ULSFrequency(
                uid: hit.uid,
                callSign: hit.callSign,
                locationNumber: 0,
                frequencyHz: hit.frequencyHz,
                upperBandHz: 0,
                isCarrier: false,
                classStationCode: "",
                powerOutput: "",
                status: ""
            )
            out.append(NearMeResult(
                frequency: f,
                distanceKm: d,
                city: hit.city,
                county: hit.county
            ))
        }
        out.sort { $0.distanceKm < $1.distanceKm }
        return Array(out.prefix(limit))
    }

    static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dlat = (lat2 - lat1) * .pi / 180.0
        let dlon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dlat / 2) * sin(dlat / 2)
            + cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) * sin(dlon / 2) * sin(dlon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: Stats

    public func stats() async throws -> (licenses: Int, frequencies: Int, locations: Int) {
        try await dbPool.read { db in
            let l = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM licenses") ?? 0
            let f = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frequencies") ?? 0
            let loc = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM locations") ?? 0
            return (l, f, loc)
        }
    }

    // MARK: Codeplug persistence

    public func saveCodeplug(_ codeplug: Codeplug) async throws {
        struct Row: Codable, FetchableRecord, PersistableRecord {
            var id: String
            var name: String
            var target: String
            var channelsJSON: String
            var createdAt: Date
            var updatedAt: Date
        }
        let data = try JSONEncoder().encode(codeplug.channels)
        let json = String(decoding: data, as: UTF8.self)
        _ = try await dbPool.write { db in
            var row = Row(
                id: codeplug.id.uuidString,
                name: codeplug.name,
                target: codeplug.target.rawValue,
                channelsJSON: json,
                createdAt: codeplug.createdAt,
                updatedAt: codeplug.updatedAt
            )
            try row.save(db)
        }
    }

    public func codeplugs() async throws -> [Codeplug] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM codeplugs ORDER BY updatedAt DESC")
            return rows.compactMap { row in
                guard let id = row["id"] as String?,
                      let name = row["name"] as String?,
                      let targetRaw = row["target"] as String?,
                      let json = row["channelsJSON"] as String?,
                      let target = RadioTarget(rawValue: targetRaw),
                      let channelData = json.data(using: .utf8),
                      let channels = try? JSONDecoder().decode([CodeplugChannel].self, from: channelData)
                else { return nil }
                return Codeplug(
                    id: UUID(uuidString: id) ?? UUID(),
                    name: name,
                    target: target,
                    channels: channels,
                    createdAt: row["createdAt"] ?? Date(),
                    updatedAt: row["updatedAt"] ?? Date()
                )
            }
        }
    }

    public func deleteCodeplug(id: UUID) async throws {
        _ = try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM codeplugs WHERE id = ?", arguments: [id.uuidString])
        }
    }
}

import Foundation
import GRDB
import CryptoKit

// MARK: - Pack builder
//
// FCC ULS archives → one read-only SQLite pack per state.
//
// Memory stays bounded: license headers are read first to learn which licenses are
// active (about a tenth of the file), then every other table is streamed through that
// uid filter into a scratch SQLite, and each state's pack is derived from the scratch
// database with SQL.

public struct PackBuildProgress: Sendable {
    public var phase: String
    public var fraction: Double

    public init(phase: String, fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }
}

public enum PackBuilderError: Error, LocalizedError, Equatable {
    case noActiveLicenses
    case noMatchingStates

    public var errorDescription: String? {
        switch self {
        case .noActiveLicenses: return "The FCC archives contained no active licenses."
        case .noMatchingStates: return "None of the requested states appear in the FCC data."
        }
    }
}

public struct PackBuilder: Sendable {
    public let workDirectory: URL
    public let outputDirectory: URL

    public init(workDirectory: URL, outputDirectory: URL) {
        self.workDirectory = workDirectory
        self.outputDirectory = outputDirectory
    }

    // MARK: Entry point

    public func build(
        sources: [any ULSTableSource],
        states: Set<String>?,
        snapshotDate: String,
        progress: (@Sendable (PackBuildProgress) -> Void)? = nil
    ) throws -> PackManifest {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: workDirectory)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        func report(_ phase: String, _ fraction: Double) {
            progress?(PackBuildProgress(phase: phase, fraction: fraction))
        }

        let stagingURL = workDirectory.appendingPathComponent("staging.sqlite")
        let staging = try DatabaseQueue(path: stagingURL.path)
        try staging.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = OFF")
            try db.execute(sql: "PRAGMA synchronous = OFF")
        }
        try staging.write { try $0.execute(sql: Self.stagingSchema) }

        report("Reading licenses", 0.02)
        let active = try stageLicenses(sources: sources, into: staging)
        guard !active.isEmpty else { throw PackBuilderError.noActiveLicenses }

        let filter: @Sendable (Int64) -> Bool = { active.contains($0) }
        report("Reading licensees", 0.10)
        try stageEntities(sources: sources, uidFilter: filter, into: staging)
        report("Reading locations", 0.25)
        try stageLocations(sources: sources, uidFilter: filter, into: staging)
        report("Reading frequencies", 0.45)
        try stageFrequencies(sources: sources, uidFilter: filter, into: staging)
        report("Reading emissions", 0.60)
        try stageEmissions(sources: sources, uidFilter: filter, into: staging)
        report("Indexing", 0.75)
        try staging.write { try $0.execute(sql: Self.stagingFinalize) }

        let available = try staging.read {
            try String.fetchAll($0, sql: "SELECT DISTINCT state FROM st_site WHERE state != '' ORDER BY state")
        }
        let known = Set(USStateCatalog.states.map(\.code))
        let targets = available.filter { known.contains($0) && (states?.contains($0) ?? true) }
        guard !targets.isEmpty else { throw PackBuilderError.noMatchingStates }

        var packs: [PackedState] = []
        for (index, state) in targets.enumerated() {
            report("Building \(state)", 0.75 + 0.25 * Double(index) / Double(targets.count))
            packs.append(try makePack(state: state, stagingURL: stagingURL, snapshotDate: snapshotDate))
        }

        let manifest = PackManifest(
            fccSnapshotDate: snapshotDate,
            builtAt: ISO8601DateFormatter().string(from: Date()),
            packs: packs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: outputDirectory.appendingPathComponent(PackManifest.fileName), options: .atomic)
        report("Done", 1.0)
        return manifest
    }

    // MARK: Staging

    private func stageLicenses(sources: [any ULSTableSource], into staging: DatabaseQueue) throws -> Set<Int64> {
        var active = Set<Int64>()
        try staging.write { db in
            let insert = try db.makeStatement(sql: "INSERT OR IGNORE INTO st_license VALUES (?, ?, ?, ?, ?)")
            for source in sources {
                guard source.hasTable(.HD) else { throw ULSTableSourceError.missingTable(.HD) }
                try ULSStream.forEachRecord(in: source, table: .HD) { record in
                    guard let license = ULSParser.parseLicense(record), license.licenseStatus == "A" else { return }
                    active.insert(license.uid)
                    try insert.execute(arguments: [license.uid, license.callSign, license.radioServiceCode,
                                                   license.grantDate, license.expiredDate])
                }
            }
        }
        return active
    }

    private func stageEntities(sources: [any ULSTableSource], uidFilter: @escaping @Sendable (Int64) -> Bool,
                               into staging: DatabaseQueue) throws {
        try staging.write { db in
            // A license lists several entities (contact, agent, licensee ...). The licensee ("L") must win
            // regardless of row order.
            let replace = try db.makeStatement(sql: "INSERT OR REPLACE INTO st_entity VALUES (?, ?, ?, ?, ?, ?)")
            let ignore = try db.makeStatement(sql: "INSERT OR IGNORE INTO st_entity VALUES (?, ?, ?, ?, ?, ?)")
            for source in sources where source.hasTable(.EN) {
                try ULSStream.forEachRecord(in: source, table: .EN, uidFilter: uidFilter) { record in
                    guard let entity = ULSParser.parseEntity(record) else { return }
                    let statement = entity.entityType == "L" ? replace : ignore
                    try statement.execute(arguments: [entity.uid, entity.entityType, entity.name,
                                                      entity.city, entity.state, entity.zipCode])
                }
            }
        }
    }

    private func stageLocations(sources: [any ULSTableSource], uidFilter: @escaping @Sendable (Int64) -> Bool,
                                into staging: DatabaseQueue) throws {
        try staging.write { db in
            let insert = try db.makeStatement(sql: "INSERT OR IGNORE INTO st_site VALUES (?, ?, ?, ?, ?, ?, ?)")
            for source in sources where source.hasTable(.LO) {
                try ULSStream.forEachRecord(in: source, table: .LO, uidFilter: uidFilter) { record in
                    guard let uid = Int64(record.field(1)) else { return }
                    let lat = ULSParser.coordinate(degrees: record.field(19), minutes: record.field(20),
                                                   seconds: record.field(21), direction: record.field(22))
                    let lon = ULSParser.coordinate(degrees: record.field(23), minutes: record.field(24),
                                                   seconds: record.field(25), direction: record.field(26))
                    // Missing or all-zero coordinates are "unknown", never a point at (0, 0).
                    var latitude = lat
                    var longitude = lon
                    if lat == nil || lon == nil || (lat == 0 && lon == 0) {
                        latitude = nil
                        longitude = nil
                    }
                    try insert.execute(arguments: [uid, Int(record.field(8)) ?? 0, record.field(12),
                                                   record.field(13), record.field(14), latitude, longitude])
                }
            }
        }
    }

    private func stageFrequencies(sources: [any ULSTableSource], uidFilter: @escaping @Sendable (Int64) -> Bool,
                                  into staging: DatabaseQueue) throws {
        try staging.write { db in
            let insert = try db.makeStatement(sql: "INSERT OR IGNORE INTO st_freq VALUES (?, ?, ?, ?, ?, ?)")
            for source in sources where source.hasTable(.FR) {
                try ULSStream.forEachRecord(in: source, table: .FR, uidFilter: uidFilter) { record in
                    guard let frequency = ULSParser.parseFrequency(record) else { return }
                    let upper: Double? = frequency.upperBandHz > 0 ? frequency.upperBandHz.rounded() : nil
                    try insert.execute(arguments: [frequency.uid, frequency.locationNumber, frequency.frequencyHz.rounded(),
                                                   upper, frequency.classStationCode, Double(frequency.powerOutput)])
                }
            }
        }
    }

    private func stageEmissions(sources: [any ULSTableSource], uidFilter: @escaping @Sendable (Int64) -> Bool,
                                into staging: DatabaseQueue) throws {
        try staging.write { db in
            let insert = try db.makeStatement(sql: "INSERT INTO st_em VALUES (?, ?, ?, ?, ?)")
            for source in sources where source.hasTable(.EM) {
                try ULSStream.forEachRecord(in: source, table: .EM, uidFilter: uidFilter) { record in
                    guard let uid = Int64(record.field(1)), let mhz = Double(record.field(7)) else { return }
                    let info = EmissionDesignator.parse(record.field(9))
                    try insert.execute(arguments: [uid, Int(record.field(5)) ?? 0, (mhz * 1_000_000).rounded(),
                                                   info.modeHint.rawValue, info.bandwidthHz])
                }
            }
        }
    }

    // MARK: Per-state packs

    private func makePack(state: String, stagingURL: URL, snapshotDate: String) throws -> PackedState {
        let fileManager = FileManager.default
        let packURL = workDirectory.appendingPathComponent("SH-\(state).sqlite")

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("county_id", argumentCount: 2, pure: true) { values in
                guard let raw = String.fromDatabaseValue(values[0]),
                      let state = String.fromDatabaseValue(values[1]) else { return nil }
                return CountyNormalizer.countyID(raw: raw, stateCode: state)
            })
            db.add(function: DatabaseFunction("county_name", argumentCount: 2, pure: true) { values in
                guard let raw = String.fromDatabaseValue(values[0]),
                      let state = String.fromDatabaseValue(values[1]) else { return nil }
                let key = CountyNormalizer.key(raw)
                return key.isEmpty ? nil : CountyNormalizer.displayName(key: key, stateCode: state)
            })
        }

        let pack = try DatabaseQueue(path: packURL.path, configuration: configuration)
        let counts: (licenses: Int, sites: Int, frequencies: Int) = try pack.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = OFF")
            try db.execute(sql: "PRAGMA synchronous = OFF")
            try db.execute(sql: "ATTACH DATABASE ? AS stg", arguments: [stagingURL.path])
            try db.inTransaction {
                try db.execute(sql: Self.packSchema)
                try db.execute(sql: Self.packFill, arguments: ["state": state])
                try db.execute(sql: "INSERT INTO meta VALUES ('schemaVersion', ?), ('stateCode', ?), ('fccSnapshotDate', ?), ('builtAt', ?)",
                               arguments: [String(packSchemaVersion), state, snapshotDate, ISO8601DateFormatter().string(from: Date())])
                return .commit
            }
            try db.execute(sql: "DETACH DATABASE stg")
            try db.execute(sql: "VACUUM")
            return (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM licenses") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sites") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frequencies") ?? 0
            )
        }

        let raw = try Data(contentsOf: packURL, options: .mappedIfSafe)
        let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
        let fileName = "SH-\(state)-\(snapshotDate.replacingOccurrences(of: "-", with: "")).sqlite.lzfse"
        try compressed.write(to: outputDirectory.appendingPathComponent(fileName), options: .atomic)
        let digest = SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined()
        let expandedBytes = Int64(raw.count)
        try? fileManager.removeItem(at: packURL)

        return PackedState(
            stateCode: state, fileName: fileName,
            compressedBytes: Int64(compressed.count), expandedBytes: expandedBytes, sha256: digest,
            licenseCount: counts.licenses, siteCount: counts.sites, frequencyCount: counts.frequencies
        )
    }

    // MARK: SQL

    private static let stagingSchema = """
    CREATE TABLE st_license(uid INTEGER PRIMARY KEY, callSign TEXT NOT NULL, serviceCode TEXT NOT NULL,
                            grantDate TEXT NOT NULL, expiredDate TEXT NOT NULL);
    CREATE TABLE st_entity(uid INTEGER PRIMARY KEY, entityType TEXT NOT NULL, name TEXT NOT NULL,
                           city TEXT NOT NULL, state TEXT NOT NULL, zip TEXT NOT NULL);
    CREATE TABLE st_site(uid INTEGER NOT NULL, locationNumber INTEGER NOT NULL, city TEXT NOT NULL,
                         county TEXT NOT NULL, state TEXT NOT NULL, latitude REAL, longitude REAL,
                         PRIMARY KEY(uid, locationNumber));
    CREATE TABLE st_freq(uid INTEGER NOT NULL, locationNumber INTEGER NOT NULL, frequencyHz REAL NOT NULL,
                         upperBandHz REAL, classStationCode TEXT NOT NULL, powerW REAL,
                         UNIQUE(uid, locationNumber, frequencyHz, classStationCode));
    CREATE TABLE st_em(uid INTEGER NOT NULL, locationNumber INTEGER NOT NULL, frequencyHz REAL NOT NULL,
                       modeHint TEXT NOT NULL, bandwidthHz REAL);
    """

    /// Fallback sites for licenses that have no location rows (GMRS, some mobile-only licenses),
    /// then the per-frequency emission summary the packs join against.
    private static let stagingFinalize = """
    INSERT OR IGNORE INTO st_site
        SELECT l.uid, 0, e.city, '', e.state, NULL, NULL
        FROM st_license l JOIN st_entity e ON e.uid = l.uid
        WHERE e.state != '' AND NOT EXISTS (SELECT 1 FROM st_site s WHERE s.uid = l.uid);
    CREATE TABLE st_em_agg AS
        SELECT uid, locationNumber, CAST(frequencyHz AS INTEGER) AS hz,
               group_concat(DISTINCT modeHint) AS modes, MAX(bandwidthHz) AS bw
        FROM st_em GROUP BY uid, locationNumber, CAST(frequencyHz AS INTEGER);
    CREATE INDEX st_em_agg_key ON st_em_agg(uid, locationNumber, hz);
    CREATE INDEX st_site_state ON st_site(state);
    """

    private static let packSchema = """
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE counties(countyId TEXT PRIMARY KEY, name TEXT NOT NULL, stateCode TEXT NOT NULL,
                          licenseCount INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE licenses(uid INTEGER PRIMARY KEY, callSign TEXT NOT NULL, licenseeName TEXT NOT NULL,
                          entityType TEXT NOT NULL, serviceCode TEXT NOT NULL, grantDate TEXT NOT NULL,
                          expiredDate TEXT NOT NULL, city TEXT NOT NULL, zip TEXT NOT NULL);
    CREATE TABLE sites(uid INTEGER NOT NULL, locationNumber INTEGER NOT NULL, city TEXT NOT NULL, countyId TEXT,
                       stateCode TEXT NOT NULL, latitude REAL, longitude REAL, PRIMARY KEY(uid, locationNumber));
    CREATE TABLE frequencies(uid INTEGER NOT NULL, locationNumber INTEGER NOT NULL, frequencyHz REAL NOT NULL,
                             upperBandHz REAL, classStationCode TEXT NOT NULL, powerW REAL,
                             modeHints TEXT NOT NULL, bandwidthHz REAL,
                             UNIQUE(uid, locationNumber, frequencyHz, classStationCode));
    """

    /// Every statement is scoped by the shared named parameter `:state`.
    private static let packFill = """
    INSERT OR IGNORE INTO counties(countyId, name, stateCode)
        SELECT DISTINCT county_id(county, state), county_name(county, state), state
        FROM stg.st_site WHERE state = :state AND county != '' AND county_id(county, state) IS NOT NULL;
    INSERT INTO sites
        SELECT uid, locationNumber, city, county_id(county, state), state, latitude, longitude
        FROM stg.st_site WHERE state = :state;
    INSERT INTO licenses
        SELECT l.uid, l.callSign, COALESCE(e.name, ''), COALESCE(e.entityType, ''), l.serviceCode,
               l.grantDate, l.expiredDate, COALESCE(e.city, ''), COALESCE(e.zip, '')
        FROM stg.st_license l LEFT JOIN stg.st_entity e ON e.uid = l.uid
        WHERE l.uid IN (SELECT uid FROM sites);
    INSERT OR IGNORE INTO frequencies
        SELECT f.uid, f.locationNumber, f.frequencyHz, f.upperBandHz, f.classStationCode, f.powerW,
               COALESCE(m.modes, 'unknown'), m.bw
        FROM stg.st_freq f
        JOIN sites s ON s.uid = f.uid AND s.locationNumber = f.locationNumber
        LEFT JOIN stg.st_em_agg m
               ON m.uid = f.uid AND m.locationNumber = f.locationNumber AND m.hz = CAST(f.frequencyHz AS INTEGER)
        WHERE s.stateCode = :state;
    UPDATE counties SET licenseCount =
        (SELECT COUNT(DISTINCT uid) FROM sites WHERE sites.countyId = counties.countyId);
    CREATE VIRTUAL TABLE licenses_fts USING fts5(callSign, licenseeName, content='licenses', content_rowid='uid');
    INSERT INTO licenses_fts(rowid, callSign, licenseeName) SELECT uid, callSign, licenseeName FROM licenses;
    CREATE INDEX sites_county ON sites(countyId);
    CREATE INDEX sites_geo ON sites(latitude, longitude);
    CREATE INDEX freq_hz ON frequencies(frequencyHz);
    CREATE INDEX freq_uid ON frequencies(uid);
    """
}

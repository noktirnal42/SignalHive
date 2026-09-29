import Testing
import Foundation
import GRDB
@testable import SignalHiveCore

struct PackBuilderTests {

    /// Builds packs from the fixture tables and returns the manifest plus the output directory.
    static func build() throws -> (manifest: PackManifest, output: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID())")
        let tables = root.appendingPathComponent("tables")
        let output = root.appendingPathComponent("out")
        try FixtureTables.write(to: tables)
        let manifest = try PackBuilder(workDirectory: root.appendingPathComponent("work"), outputDirectory: output)
            .build(sources: [DirectoryTableSource(directory: tables)], states: nil,
                   snapshotDate: "2026-09-25", progress: nil)
        return (manifest, output)
    }

    /// Decompresses one state's pack and opens it read-only.
    static func open(_ manifest: PackManifest, _ output: URL, _ state: String) throws -> DatabaseQueue {
        let entry = try #require(manifest.packs.first { $0.stateCode == state })
        let compressed = try Data(contentsOf: output.appendingPathComponent(entry.fileName))
        let raw = try (compressed as NSData).decompressed(using: .lzfse) as Data
        let path = output.appendingPathComponent("\(state)-test.sqlite")
        try raw.write(to: path)
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: path.path, configuration: configuration)
    }

    @Test func onlyActiveLicensesAreKept() throws {
        let (manifest, output) = try Self.build()
        let db = try Self.open(manifest, output, "AL")
        let calls = try db.read { try String.fetchAll($0, sql: "SELECT callSign FROM licenses ORDER BY callSign") }
        #expect(calls == ["KAAA111", "KBBB222", "KDDD444"])   // KCCC333 is cancelled
    }

    @Test func licenseeRowWinsOverEarlierContactRow() throws {
        let (manifest, output) = try Self.build()
        let db = try Self.open(manifest, output, "AL")
        let name = try db.read { try String.fetchOne($0, sql: "SELECT licenseeName FROM licenses WHERE callSign = 'KAAA111'") }
        #expect(name == "COFFEE COUNTY SHERIFF")
    }

    @Test func blankCoordinatesBecomeNullNotZero() throws {
        let (manifest, output) = try Self.build()
        let db = try Self.open(manifest, output, "AL")
        let row = try #require(db.read { try Row.fetchOne($0, sql: "SELECT latitude, longitude FROM sites WHERE uid = 1001 AND locationNumber = 2") })
        let latitude: Double? = row["latitude"]
        let longitude: Double? = row["longitude"]
        #expect(latitude == nil)
        #expect(longitude == nil)
        let good = try #require(db.read { try Row.fetchOne($0, sql: "SELECT latitude, longitude FROM sites WHERE uid = 1001 AND locationNumber = 1") })
        #expect(abs((good["latitude"] as Double) - 31.31861) < 0.0001)
        #expect(abs((good["longitude"] as Double) - (-85.83278)) < 0.0001)
    }

    @Test func licenseWithSitesInTwoStatesAppearsInBothWithOnlyLocalSites() throws {
        let (manifest, output) = try Self.build()
        for (state, expectedLocation) in [("AL", 1), ("GA", 2)] {
            let db = try Self.open(manifest, output, state)
            let locations = try db.read { try Int.fetchAll($0, sql: "SELECT locationNumber FROM sites WHERE uid = 1002") }
            #expect(locations == [expectedLocation], "state \(state)")
            let licensed = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM licenses WHERE uid = 1002") }
            #expect(licensed == 1, "state \(state)")
        }
    }

    @Test func modeHintsAndCountiesAreDerived() throws {
        let (manifest, output) = try Self.build()
        let db = try Self.open(manifest, output, "AL")
        let hints = try db.read {
            try String.fetchOne($0, sql: "SELECT modeHints FROM frequencies WHERE uid = 1001 AND frequencyHz = 856012500")
        }
        #expect(hints?.contains("digitalP25") == true)
        #expect(hints?.contains("analogFM") == true)
        let county = try #require(db.read { try Row.fetchOne($0, sql: "SELECT name, licenseCount FROM counties WHERE countyId = 'AL:COFFEE'") })
        #expect(county["name"] as String == "Coffee County")
        #expect(county["licenseCount"] as Int == 1)
    }

    @Test func licenseWithoutLocationTableGetsFallbackSiteFromEntity() throws {
        let (manifest, output) = try Self.build()
        let db = try Self.open(manifest, output, "AL")
        let city = try db.read { try String.fetchOne($0, sql: "SELECT city FROM sites WHERE uid = 1003") }
        #expect(city == "OZARK")
    }

    @Test func searchIndexAndManifestAreComplete() throws {
        let (manifest, output) = try Self.build()
        #expect(manifest.schemaVersion == packSchemaVersion)
        #expect(manifest.fccSnapshotDate == "2026-09-25")
        #expect(Set(manifest.packs.map(\.stateCode)) == ["AL", "GA"])
        #expect(manifest.packs.allSatisfy { $0.sha256.count == 64 && $0.compressedBytes > 0 && $0.expandedBytes > $0.compressedBytes / 4 })
        let db = try Self.open(manifest, output, "AL")
        let hit = try db.read { try Int.fetchOne($0, sql: "SELECT rowid FROM licenses_fts WHERE licenses_fts MATCH 'sheriff*'") }
        #expect(hit == 1001)
    }

    @Test func stateFilterLimitsOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID())")
        try FixtureTables.write(to: root.appendingPathComponent("tables"))
        let manifest = try PackBuilder(workDirectory: root.appendingPathComponent("work"),
                                       outputDirectory: root.appendingPathComponent("out"))
            .build(sources: [DirectoryTableSource(directory: root.appendingPathComponent("tables"))],
                   states: ["GA"], snapshotDate: "2026-09-25", progress: nil)
        #expect(manifest.packs.map(\.stateCode) == ["GA"])
    }
}

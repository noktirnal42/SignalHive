import Testing
import Foundation
import GRDB
@testable import SignalHiveCore

struct UserDatabaseTests {

    static func tempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID()).sqlite").path
    }

    static func sample(_ name: String) -> Codeplug {
        var plug = Codeplug(name: name, target: .baofengUV5R)
        plug.add(channel: CodeplugChannel(name: "SHERIFF", frequencyHz: 155_475_000, mode: .nfm, ctcssToneHz: 123.0))
        return plug
    }

    /// The pre-pack database layout. (The old `AppDatabase.saveCodeplug` could never write to it: a nested
    /// struct named `Row` made GRDB target a table called "row". So legacy files are built directly.)
    static func makeLegacy(at path: String, _ plugs: [Codeplug]) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE codeplugs (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, target TEXT NOT NULL,
                                        channelsJSON TEXT NOT NULL, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL)
                """)
            for plug in plugs {
                let json = String(decoding: try JSONEncoder().encode(plug.channels), as: UTF8.self)
                try db.execute(sql: "INSERT INTO codeplugs VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [plug.id.uuidString, plug.name, plug.target.rawValue, json, plug.createdAt, plug.updatedAt])
            }
        }
    }

    @Test func saveListAndDeleteRoundTrip() async throws {
        let db = try await UserDatabase.open(at: Self.tempPath("user"))
        let plug = Self.sample("Local")
        try await db.saveCodeplug(plug)
        let listed = try await db.codeplugs()
        #expect(listed.map(\.name) == ["Local"])
        #expect(listed.first?.channels.first?.frequencyHz == 155_475_000)
        try await db.deleteCodeplug(id: plug.id)
        #expect(try await db.codeplugs().isEmpty)
    }

    @Test func legacyCodeplugsMigrateOnceAndADeletedOneNeverComesBack() async throws {
        let legacyPath = Self.tempPath("legacy")
        let first = Self.sample("Legacy A"), second = Self.sample("Legacy B")
        try Self.makeLegacy(at: legacyPath, [first, second])

        let user = try await UserDatabase.open(at: Self.tempPath("user"))
        #expect(try await user.migrateCodeplugsIfNeeded(fromLegacy: legacyPath) == 2)
        #expect(Set(try await user.codeplugs().map(\.name)) == ["Legacy A", "Legacy B"])
        let legacyRows = try await DatabaseQueue(path: legacyPath).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM codeplugs") }
        #expect(legacyRows == 2)                                       // legacy file untouched

        try await user.deleteCodeplug(id: first.id)
        #expect(try await user.migrateCodeplugsIfNeeded(fromLegacy: legacyPath) == 0)
        #expect(try await user.codeplugs().map(\.name) == ["Legacy B"])   // not resurrected
    }

    @Test func missingLegacyFileIsNotAnError() async throws {
        let user = try await UserDatabase.open(at: Self.tempPath("user"))
        #expect(try await user.migrateCodeplugsIfNeeded(fromLegacy: "/nonexistent/legacy.sqlite") == 0)
    }
}

// MARK: - Antennas (migration v2)

extension UserDatabaseTests {
    private static func antenna(_ name: String, mhz: ClosedRange<Double>) -> AntennaProfile {
        AntennaProfile(id: UUID(), name: name, lowHz: mhz.lowerBound * 1e6, highHz: mhz.upperBound * 1e6, gain: .omni,
                       isDirectional: false, notes: "")
    }

    @Test func antennasPersistAndReload() async throws {
        let path = Self.tempPath("antennas")
        let db = try await UserDatabase.open(at: path)
        #expect(try await db.antennas().isEmpty)

        var mast = Self.antenna("Telescopic mast", mhz: 100...800)
        let turnstile = Self.antenna("Turnstile", mhz: 136...138)
        try await db.saveAntenna(mast)
        try await db.saveAntenna(turnstile)
        #expect(Set(try await db.antennas().map(\.name)) == ["Telescopic mast", "Turnstile"])

        // Saving again with the same id updates it rather than adding a second row.
        mast.notes = "set to 53 cm"
        try await db.saveAntenna(mast)
        let listed = try await db.antennas()
        #expect(listed.count == 2)
        #expect(listed.first { $0.id == mast.id }?.notes == "set to 53 cm")

        // And they are still there after the file is reopened.
        let reopened = try await UserDatabase.open(at: path)
        #expect(Set(try await reopened.antennas().map(\.id)) == [mast.id, turnstile.id])

        try await reopened.deleteAntenna(id: turnstile.id)
        #expect(try await reopened.antennas().map(\.id) == [mast.id])
    }

    @Test func migrationV2KeepsExistingCodeplugs() async throws {
        // A database exactly as the app wrote it before antennas existed: migration "v1" applied, one codeplug in it.
        let path = Self.tempPath("v1-only")
        let plug = Self.sample("Before antennas")
        let queue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "codeplugs") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("target", .text).notNull()
                t.column("channelsJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "user_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        try migrator.migrate(queue)
        let json = String(decoding: try JSONEncoder().encode(plug.channels), as: UTF8.self)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO codeplugs VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [plug.id.uuidString, plug.name, plug.target.rawValue, json, plug.createdAt, plug.updatedAt])
        }
        let hadAntennas = try await queue.read { try $0.tableExists("antennas") }
        #expect(!hadAntennas)

        let db = try await UserDatabase.open(at: path)
        #expect(try await db.codeplugs().map(\.name) == ["Before antennas"])
        #expect(try await db.codeplugs().first?.channels.first?.frequencyHz == 155_475_000)
        #expect(try await db.antennas().isEmpty)
        try await db.saveAntenna(Self.antenna("After", mhz: 100...200))
        #expect(try await db.antennas().count == 1)
        let hasAntennas = try await DatabaseQueue(path: path).read { try $0.tableExists("antennas") }
        #expect(hasAntennas)
    }
}

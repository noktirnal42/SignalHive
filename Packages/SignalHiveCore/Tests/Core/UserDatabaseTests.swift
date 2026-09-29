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

import Foundation
import GRDB

// MARK: - UserDatabase
//
// Everything the user creates lives here (`UserData.sqlite`), separate from the read-only FCC
// packs so updating or deleting FCC data can never touch a codeplug.

public actor UserDatabase {
    private let queue: DatabaseQueue

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public static func open(at path: String) async throws -> UserDatabase {
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
        return UserDatabase(queue: queue)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("SignalHive", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("UserData.sqlite")
    }

    // MARK: Codeplugs

    public func saveCodeplug(_ codeplug: Codeplug) throws {
        let channels = String(decoding: try JSONEncoder().encode(codeplug.channels), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO codeplugs (id, name, target, channelsJSON, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, target = excluded.target, channelsJSON = excluded.channelsJSON,
                    updatedAt = excluded.updatedAt
                """, arguments: [codeplug.id.uuidString, codeplug.name, codeplug.target.rawValue, channels,
                                 codeplug.createdAt, codeplug.updatedAt])
        }
    }

    public func codeplugs() throws -> [Codeplug] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM codeplugs ORDER BY updatedAt DESC").compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let target = RadioTarget(rawValue: row["target"]),
                      let json = (row["channelsJSON"] as String).data(using: .utf8),
                      let channels = try? JSONDecoder().decode([CodeplugChannel].self, from: json)
                else { return nil }
                return Codeplug(id: id, name: row["name"], target: target, channels: channels,
                                createdAt: row["createdAt"] ?? Date(), updatedAt: row["updatedAt"] ?? Date())
            }
        }
    }

    public func deleteCodeplug(id: UUID) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM codeplugs WHERE id = ?", arguments: [id.uuidString]) }
    }

    // MARK: Legacy migration

    /// Copies codeplugs from the pre-pack `SignalHive.sqlite` once. A marker prevents a codeplug the user
    /// later deletes from being copied back on the next launch. Returns how many rows were copied.
    @discardableResult
    public func migrateCodeplugsIfNeeded(fromLegacy legacyPath: String) throws -> Int {
        let alreadyDone = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM user_meta WHERE key = 'legacyCodeplugsMigrated'") != nil
        }
        guard !alreadyDone else { return 0 }
        guard FileManager.default.fileExists(atPath: legacyPath) else { return 0 }

        var configuration = Configuration()
        configuration.readonly = true
        let legacy = try DatabaseQueue(path: legacyPath, configuration: configuration)
        let rows = try legacy.read { db -> [Row] in
            guard try db.tableExists("codeplugs") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT * FROM codeplugs")
        }
        return try queue.write { db in
            var copied = 0
            for row in rows {
                let id: DatabaseValue = row["id"]
                let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM codeplugs WHERE id = ?", arguments: [id]) ?? 0
                guard exists == 0 else { continue }
                let name: DatabaseValue = row["name"], target: DatabaseValue = row["target"]
                let channels: DatabaseValue = row["channelsJSON"]
                let created: DatabaseValue = row["createdAt"], updated: DatabaseValue = row["updatedAt"]
                try db.execute(sql: """
                    INSERT INTO codeplugs (id, name, target, channelsJSON, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [id, name, target, channels, created, updated])
                copied += 1
            }
            try db.execute(sql: "INSERT OR REPLACE INTO user_meta VALUES ('legacyCodeplugsMigrated', '1')")
            return copied
        }
    }
}

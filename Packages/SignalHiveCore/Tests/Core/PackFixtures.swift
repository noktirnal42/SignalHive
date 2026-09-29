import Foundation
import Testing
import GRDB
import CryptoKit
@testable import SignalHiveCore

/// Builds a fake "pack server" directory (manifest + packs) from the fixture tables, and helpers
/// to tamper with it.
enum PackFixtures {

    static func publish(snapshot: String = "2026-09-25", states: Set<String>? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("srv-\(UUID())")
        try FixtureTables.write(to: root.appendingPathComponent("tables"))
        let server = root.appendingPathComponent("server")
        _ = try PackBuilder(workDirectory: root.appendingPathComponent("work"), outputDirectory: server)
            .build(sources: [DirectoryTableSource(directory: root.appendingPathComponent("tables"))],
                   states: states, snapshotDate: snapshot, progress: nil)
        return server
    }

    static func makeStore(server: URL?, available: @escaping @Sendable () -> Int64 = { .max }) -> (store: PackStore, install: URL) {
        let install = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID())")
        return (PackStore(manifestBaseURL: server, installDirectory: install, availableBytes: available), install)
    }

    static func readManifest(_ server: URL) throws -> PackManifest {
        try JSONDecoder().decode(PackManifest.self, from: Data(contentsOf: server.appendingPathComponent("manifest.json")))
    }

    static func writeManifest(_ manifest: PackManifest, to server: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: server.appendingPathComponent("manifest.json"))
    }

    /// Flips one byte in the middle of a published pack (checksum in the manifest is left alone).
    static func corrupt(_ state: String, in server: URL) throws {
        let manifest = try readManifest(server)
        let entry = try #require(manifest.packs.first { $0.stateCode == state })
        let url = server.appendingPathComponent(entry.fileName)
        var data = try Data(contentsOf: url)
        data[data.count / 2] ^= 0xFF
        try data.write(to: url)
    }

    /// Rewrites a pack's schema version and fixes up the manifest checksum so only the schema check can fail.
    static func setSchemaVersion(_ version: Int, of state: String, in server: URL) throws {
        var manifest = try readManifest(server)
        let index = try #require(manifest.packs.firstIndex { $0.stateCode == state })
        let url = server.appendingPathComponent(manifest.packs[index].fileName)
        let raw = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data
        let scratch = server.appendingPathComponent("scratch-\(UUID()).sqlite")
        try raw.write(to: scratch)
        try DatabaseQueue(path: scratch.path).write {
            try $0.execute(sql: "UPDATE meta SET value = ? WHERE key = 'schemaVersion'", arguments: [String(version)])
        }
        let recompressed = try (Data(contentsOf: scratch) as NSData).compressed(using: .lzfse) as Data
        try recompressed.write(to: url)
        try? FileManager.default.removeItem(at: scratch)
        manifest.packs[index].sha256 = SHA256.hash(data: recompressed).map { String(format: "%02x", $0) }.joined()
        manifest.packs[index].compressedBytes = Int64(recompressed.count)
        try writeManifest(manifest, to: server)
    }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PackStatus] = []
    func add(_ status: PackStatus) { lock.lock(); items.append(status); lock.unlock() }
    var all: [PackStatus] { lock.lock(); defer { lock.unlock() }; return items }
}

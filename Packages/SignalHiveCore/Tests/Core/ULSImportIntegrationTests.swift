import Foundation
import Testing
import GRDB
import SignalHiveCore

/// End-to-end integration test: ULS import → SQLite → county browse query.
/// Self-provisions from the fixture dir (opencode/uls_test) into the importer's
/// temp cache path; the importer skips download when the cache is present.
struct ULSImportIntegrationTests {

    static var realArchiveDirectory: URL? {
        guard let value = ProcessInfo.processInfo.environment["SIGNALHIVE_REAL_ARCHIVES"], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    static func provisionCache(named name: String) -> Bool {
        guard let fixtureDir = realArchiveDirectory else { return false }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        if FileManager.default.fileExists(atPath: dest) { return true }
        let source = fixtureDir.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: source) else { return false }
        try? FileManager.default.copyItem(atPath: source, toPath: dest)
        return FileManager.default.fileExists(atPath: dest)
    }

    @Test func importLMCommAndBrowseCounties() async throws {
        guard let archiveDirectory = Self.realArchiveDirectory else {
            print("Skipping real LMComm import test: set SIGNALHIVE_REAL_ARCHIVES to a directory containing l_LMcomm.zip.")
            return
        }
        guard Self.provisionCache(named: "l_LMcomm.zip") else {
            print("Skipping real LMComm import test: l_LMcomm.zip was not found in \(archiveDirectory.path).")
            return
        }
        let tempDir = FileManager.default.temporaryDirectory

        // Fresh database
        let dbPath = tempDir.appendingPathComponent("integration_test_\(UUID().uuidString).sqlite").path
        let database = try await AppDatabase.open(at: dbPath)
        try await database.seedStatesIfNeeded()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        // Import
        let importer = ULSImporter()
        let total = try await importer.importService(.lmComm, into: database)
        #expect(total > 10_000)

        let stats = try await database.stats()
        #expect(stats.licenses > 1_000)
        #expect(stats.frequencies > 1_000)
        #expect(stats.locations > 1_000)

        // Browse: Alabama counties must populate
        let alCounties = try await database.countiesWithLicenseCounts(in: "AL")
        #expect(!alCounties.isEmpty)
        #expect(alCounties.count > 20)

        // Licenses in an Alabama county must populate
        let firstCounty = alCounties[0].county
        let licenses = try await database.licenses(in: "AL", county: firstCounty.county, service: nil)
        #expect(!licenses.isEmpty)

        // License detail must resolve
        let detail = try await database.licenseDetail(uid: licenses[0].uid)
        #expect(detail.license != nil)
        #expect(detail.entity != nil)
    }

    @Test func importGMRSFallbackLocations() async throws {
        guard let archiveDirectory = Self.realArchiveDirectory else {
            print("Skipping real GMRS import test: set SIGNALHIVE_REAL_ARCHIVES to a directory containing l_gmrs.zip.")
            return
        }
        guard Self.provisionCache(named: "l_gmrs.zip") else {
            print("Skipping real GMRS import test: l_gmrs.zip was not found in \(archiveDirectory.path).")
            return
        }
        let tempDir = FileManager.default.temporaryDirectory

        let dbPath = tempDir.appendingPathComponent("gmrs_test_\(UUID().uuidString).sqlite").path
        let database = try await AppDatabase.open(at: dbPath)
        try await database.seedStatesIfNeeded()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let importer = ULSImporter()
        _ = try await importer.importService(.gmrs, into: database)

        let stats = try await database.stats()
        #expect(stats.licenses > 1_000)

        // GMRS has no FR/LO tables — fallback locations from entity addresses
        // must populate counties grouped by city.
        let alCounties = try await database.countiesWithLicenseCounts(in: "AL")
        #expect(!alCounties.isEmpty)
    }
}

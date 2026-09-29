import Foundation
import Testing
import GRDB
import SignalHiveCore

/// End-to-end integration test: ULS import → SQLite → county browse query.
/// Uses the cached l_LMcomm.zip in the temp dir (importer skips download if present).
struct ULSImportIntegrationTests {

    @Test func importLMCommAndBrowseCounties() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let cachePath = tempDir.appendingPathComponent("l_LMcomm.zip").path
        guard FileManager.default.fileExists(atPath: cachePath) else {
            Issue.record("Cache missing — copy l_LMcomm.zip to \(cachePath)")
            return
        }

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
        let tempDir = FileManager.default.temporaryDirectory
        let cachePath = tempDir.appendingPathComponent("l_gmrs.zip").path
        guard FileManager.default.fileExists(atPath: cachePath) else {
            Issue.record("Cache missing — copy l_gmrs.zip to \(cachePath)")
            return
        }

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
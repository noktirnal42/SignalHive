import Testing
import Foundation
import ZIPFoundation
@testable import SignalHiveCore

struct LocalPackServiceTests {

    /// Zips the fixture tables into a stand-in for l_LMcomm.zip.
    static func fixtureArchive() throws -> (root: URL, zip: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID())")
        let tables = root.appendingPathComponent("tables")
        try FixtureTables.write(to: tables)
        let zip = root.appendingPathComponent("l_LMcomm.zip")
        try FileManager.default.zipItem(at: tables, to: zip, shouldKeepParent: false)
        return (root, zip)
    }

    @Test func buildsPacksFromADownloadedArchiveAndCleansUpAfterItself() async throws {
        let (root, zip) = try Self.fixtureArchive()
        let work = root.appendingPathComponent("work"), output = root.appendingPathComponent("packs")
        let service = LocalPackService(workDirectory: work, outputDirectory: output,
                                       archiveURL: { _ in zip }, availableBytes: { .max })
        let manifest = try await service.build(services: [.lmComm], states: ["AL"], progress: { _ in })

        #expect(manifest.packs.map(\.stateCode) == ["AL"])
        #expect(!manifest.fccSnapshotDate.isEmpty)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("manifest.json").path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        #expect(!leftovers.contains { $0.hasSuffix(".zip") }, "downloaded archives must be deleted: \(leftovers)")

        // The output is directly installable by PackStore through a file:// base URL.
        let install = root.appendingPathComponent("install")
        let store = PackStore(manifestBaseURL: output, installDirectory: install, availableBytes: { .max })
        try await store.install(state: "AL") { _ in }
        #expect(await store.installedStates() == ["AL"])
    }

    @Test func lowDiskSpaceStopsBeforeAnyDownload() async throws {
        let (root, zip) = try Self.fixtureArchive()
        let work = root.appendingPathComponent("work")
        let service = LocalPackService(workDirectory: work, outputDirectory: root.appendingPathComponent("packs"),
                                       archiveURL: { _ in zip }, availableBytes: { 1 })
        await #expect(throws: PackStoreError.self) {
            _ = try await service.build(services: [.lmPriv], states: ["AL"], progress: { _ in })
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func aFailedDownloadReportsTheServiceAndLeavesNoArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID())")
        let missing = root.appendingPathComponent("does-not-exist.zip")
        let work = root.appendingPathComponent("work")
        let service = LocalPackService(workDirectory: work, outputDirectory: root.appendingPathComponent("packs"),
                                       archiveURL: { _ in missing }, availableBytes: { .max })
        do {
            _ = try await service.build(services: [.gmrs], states: nil, progress: { _ in })
            Issue.record("expected a download failure")
        } catch let error as LocalPackError {
            #expect(error.errorDescription?.contains("GMRS") == true)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter { $0.hasSuffix(".zip") }.isEmpty)
    }
}

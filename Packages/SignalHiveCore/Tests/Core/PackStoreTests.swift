import Testing
import Foundation
@testable import SignalHiveCore

struct PackStoreTests {

    @Test func installVerifiesDecompressesAndRegistersTheState() async throws {
        let server = try PackFixtures.publish()
        let (store, install) = PackFixtures.makeStore(server: server)
        let log = StatusLog()
        _ = try await store.refreshManifest()
        try await store.install(state: "AL") { log.add($0) }

        #expect(await store.installedStates() == ["AL"])
        let url = try #require(await store.databaseURL(for: "AL"))
        #expect(url.deletingLastPathComponent().standardizedFileURL == install.standardizedFileURL)
        #expect(try FrequencyStore(path: url.path).counties().isEmpty == false)
        #expect(log.all.contains(.verifying))
        #expect(log.all.last == .installed(snapshot: "2026-09-25"))

        let availability = await store.availability()
        #expect(availability.first { $0.code == "AL" }?.status == .installed(snapshot: "2026-09-25"))
        if case .notInstalled(let size) = availability.first(where: { $0.code == "GA" })?.status {
            #expect((size ?? 0) > 0)
        } else { Issue.record("GA should be offered for download") }
    }

    @Test func corruptedDownloadIsRejectedAndNothingIsInstalled() async throws {
        let server = try PackFixtures.publish()
        try PackFixtures.corrupt("AL", in: server)
        let (store, install) = PackFixtures.makeStore(server: server)
        await #expect(throws: PackStoreError.checksumMismatch) { try await store.install(state: "AL") { _ in } }
        #expect(await store.installedStates().isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: install.path)) ?? []
        #expect(leftovers.isEmpty)
        if case .failed = await store.availability().first(where: { $0.code == "AL" })?.status {} else {
            Issue.record("the failure should be visible in the state's status")
        }
    }

    @Test func aFailedReinstallLeavesThePreviousGoodPackUntouched() async throws {
        let server = try PackFixtures.publish()
        let (store, _) = PackFixtures.makeStore(server: server)
        try await store.install(state: "AL") { _ in }
        let before = try #require(await store.databaseURL(for: "AL"))

        try PackFixtures.corrupt("AL", in: server)
        await #expect(throws: PackStoreError.checksumMismatch) { try await store.install(state: "AL") { _ in } }

        #expect(await store.databaseURL(for: "AL") == before)
        #expect(try FrequencyStore(path: before.path).counties().isEmpty == false)
    }

    @Test func aNewerSnapshotReplacesTheOlderOneOnDisk() async throws {
        let (store, install) = PackFixtures.makeStore(server: try PackFixtures.publish(snapshot: "2026-09-25"))
        try await store.install(state: "AL") { _ in }
        // Publish a newer snapshot to a second server and point a fresh store at the same install dir.
        let newer = try PackFixtures.publish(snapshot: "2026-10-02")
        let store2 = PackStore(manifestBaseURL: newer, installDirectory: install, availableBytes: { .max })
        try await store2.install(state: "AL") { _ in }
        let files = try FileManager.default.contentsOfDirectory(atPath: install.path).sorted()
        #expect(files == ["SH-AL-20261002.sqlite"])
        #expect(await store2.availability().first { $0.code == "AL" }?.status == .installed(snapshot: "2026-10-02"))
    }

    @Test func lowDiskSpaceIsReportedBeforeDownloading() async throws {
        let (store, install) = PackFixtures.makeStore(server: try PackFixtures.publish(), available: { 1 })
        do {
            try await store.install(state: "AL") { _ in }
            Issue.record("expected insufficientSpace")
        } catch let PackStoreError.insufficientSpace(needed, available) {
            #expect(needed > 1 && available == 1)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: install.path)) ?? []).isEmpty)
    }

    @Test func packNewerThanTheAppIsRefusedAndNotInstalled() async throws {
        let server = try PackFixtures.publish()
        try PackFixtures.setSchemaVersion(99, of: "AL", in: server)
        let (store, install) = PackFixtures.makeStore(server: server)
        await #expect(throws: PackStoreError.schemaTooNew(99)) { try await store.install(state: "AL") { _ in } }
        #expect(await store.installedStates().isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: install.path)) ?? []).isEmpty)
    }

    @Test func manifestNewerThanTheAppIsRefused() async throws {
        let server = try PackFixtures.publish()
        var manifest = try PackFixtures.readManifest(server)
        manifest.schemaVersion = 99
        try PackFixtures.writeManifest(manifest, to: server)
        let (store, _) = PackFixtures.makeStore(server: server)
        await #expect(throws: PackStoreError.schemaTooNew(99)) { _ = try await store.refreshManifest() }
    }

    @Test func unknownStateAndUnavailableManifestAreReportedClearly() async throws {
        let (store, _) = PackFixtures.makeStore(server: try PackFixtures.publish())
        await #expect(throws: PackStoreError.notInManifest("ZZ")) { try await store.install(state: "ZZ") { _ in } }

        let (noServer, _) = PackFixtures.makeStore(server: nil)
        do { _ = try await noServer.refreshManifest(); Issue.record("expected manifestUnavailable") }
        catch { #expect(error is PackStoreError) }

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID())")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let (missing, _) = PackFixtures.makeStore(server: empty)
        do { _ = try await missing.refreshManifest(); Issue.record("expected manifestUnavailable") }
        catch let PackStoreError.manifestUnavailable(reason) { #expect(!reason.isEmpty) }
    }

    @Test func removeDeletesTheInstalledPack() async throws {
        let (store, install) = PackFixtures.makeStore(server: try PackFixtures.publish())
        try await store.install(state: "AL") { _ in }
        try await store.remove(state: "AL")
        #expect(await store.installedStates().isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: install.path)) ?? []).isEmpty)
    }
}

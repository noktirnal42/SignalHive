import Testing
import Foundation
@testable import SignalHiveCore

struct PackBrowseDataSourceTests {

    func source() async throws -> PackBrowseDataSource {
        let (store, _) = PackFixtures.makeStore(server: try PackFixtures.publish())
        try await store.install(state: "AL") { _ in }
        try await store.install(state: "GA") { _ in }
        return PackBrowseDataSource(packs: store)
    }

    @Test func browsesInstalledStatesAndRefusesOthers() async throws {
        let data = try await source()
        #expect(try await data.counties(in: "AL").contains { $0.name == "Coffee County" })
        await #expect(throws: BrowseDataError.stateNotInstalled("TX")) { try await data.counties(in: "TX") }
        let coffee = CountyID(stateCode: "AL", id: "AL:COFFEE")
        #expect(try await data.licenses(in: coffee, filter: .none).map(\.callSign) == ["KAAA111"])
    }

    @Test func aLicenseSpanningTwoStatesMergesItsSitesAcrossPacks() async throws {
        let data = try await source()
        let detail = try await data.detail(uid: 1002)
        #expect(Set(detail.sites.map(\.stateCode)) == ["AL", "GA"])
        #expect(detail.frequencies.count == 2)
        await #expect(throws: BrowseDataError.licenseNotFound(424242)) { _ = try await data.detail(uid: 424242) }
    }

    @Test func searchFansOutAcrossStatesWithoutDuplicates() async throws {
        let data = try await source()
        #expect(try await data.search("utility", scope: .licensee).map(\.uid) == [1002])   // in both packs, one hit
        #expect(try await data.search("452.5", scope: .frequency).contains { $0.uid == 1002 })
        let near = try await data.frequencies(near: Coordinate(latitude: 33.75, longitude: -84.39), radiusKm: 10)
        #expect(near.contains { $0.callSign == "KBBB222" })   // the Atlanta site lives in the GA pack
    }

    @Test func statesPassThroughPackAvailability() async throws {
        let data = try await source()
        let states = await data.states()
        #expect(states.first { $0.code == "AL" }?.status == .installed(snapshot: "2026-09-25"))
        #expect(states.first { $0.code == "TX" }?.status == .notInstalled(sizeBytes: nil))
    }
}

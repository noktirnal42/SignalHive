import Testing
@testable import SignalHiveCore

struct MockBrowseDataSourceTests {
    let mock = MockBrowseDataSource()

    @Test func statesCoverEveryPackStatusSoEveryUIStateCanBePreviewed() async {
        let states = await mock.states()
        #expect(states.count == USStateCatalog.states.count)
        func status(_ code: String) -> PackStatus? { states.first { $0.code == code }?.status }
        #expect(status("AL") == .installed(snapshot: "2026-09-25"))
        if case .downloading = status("GA") {} else { Issue.record("GA should be downloading") }
        if case .notInstalled(let size) = status("FL") { #expect(size != nil) } else { Issue.record("FL should be notInstalled") }
        if case .failed = status("TX") {} else { Issue.record("TX should be failed") }
    }

    @Test func alabamaHasRealisticCountiesWithLicensesAndDetail() async throws {
        let counties = try await mock.counties(in: "AL")
        #expect(counties.count >= 12)
        #expect(counties.map(\.name).sorted() == counties.map(\.name))   // alphabetical
        for county in counties {
            let licenses = try await mock.licenses(in: county.id, filter: .none)
            #expect(licenses.count == county.licenseCount)
            let first = try #require(licenses.first)
            let detail = try await mock.detail(uid: first.uid)
            #expect(detail.summary.callSign == first.callSign)
            #expect(!detail.frequencies.isEmpty && !detail.sites.isEmpty)
        }
    }

    @Test func notInstalledStatesThrowRatherThanReturnEmptyLists() async {
        await #expect(throws: BrowseDataError.stateNotInstalled("FL")) { try await mock.counties(in: "FL") }
    }

    @Test func searchAndNearbyBehaveLikeTheRealSource() async throws {
        let hits = try await mock.search("sheriff", scope: .all)
        #expect(!hits.isEmpty && hits.allSatisfy { $0.kind == .license })
        let near = try await mock.frequencies(near: Coordinate(latitude: 33.5207, longitude: -86.8025), radiusKm: 30)
        #expect(!near.isEmpty)
        #expect(near.map(\.distanceKm) == near.map(\.distanceKm).sorted())
    }

    @Test func filterAppliesToServiceAndText() async throws {
        let county = try #require(try await mock.counties(in: "AL").first)
        let all = try await mock.licenses(in: county.id, filter: .none)
        let sheriff = try await mock.licenses(in: county.id, filter: LicenseFilter(text: "sheriff"))
        #expect(sheriff.count >= 1 && sheriff.count < all.count)
        let none = try await mock.licenses(in: county.id, filter: LicenseFilter(serviceCodes: ["ZZ"]))
        #expect(none.isEmpty)
    }
}

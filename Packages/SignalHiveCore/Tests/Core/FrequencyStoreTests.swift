import Testing
import Foundation
@testable import SignalHiveCore

struct FrequencyStoreTests {

    static func store(_ state: String = "AL") throws -> FrequencyStore {
        let (manifest, output) = try PackBuilderTests.build()
        let entry = try #require(manifest.packs.first { $0.stateCode == state })
        let compressed = try Data(contentsOf: output.appendingPathComponent(entry.fileName))
        let raw = try (compressed as NSData).decompressed(using: .lzfse) as Data
        let path = output.appendingPathComponent("\(state)-store.sqlite")
        try raw.write(to: path)
        return try FrequencyStore(path: path.path)
    }

    @Test func countiesIncludeCountsAndAnUnknownBucket() throws {
        let store = try Self.store()
        let counties = try store.counties()
        let coffee = try #require(counties.first { $0.name == "Coffee County" })
        #expect(coffee.licenseCount == 1)
        #expect(coffee.id == CountyID(stateCode: "AL", id: "AL:COFFEE"))
        // KDDD444 has no county (fallback site), so it lands in the unknown bucket, listed last.
        #expect(counties.last?.name == "County unknown")
        #expect(counties.last?.licenseCount == 1)
    }

    @Test func licensesInCountyCarryFrequencyCountAndModes() throws {
        let store = try Self.store()
        let licenses = try store.licenses(in: CountyID(stateCode: "AL", id: "AL:COFFEE"), filter: .none)
        #expect(licenses.map(\.callSign) == ["KAAA111"])
        let sheriff = try #require(licenses.first)
        #expect(sheriff.licenseeName == "COFFEE COUNTY SHERIFF")
        #expect(sheriff.frequencyCount == 2)
        #expect(sheriff.modeHints == [.analogFM, .digitalP25])
        #expect(sheriff.serviceName == RadioServiceCatalog.name(for: "PW"))

        let unknown = try store.licenses(in: CountyID(stateCode: "AL", id: "AL:?"), filter: .none)
        #expect(unknown.map(\.callSign) == ["KDDD444"])
    }

    @Test func licenseFilterNarrowsByServiceAndText() throws {
        let store = try Self.store()
        let houston = CountyID(stateCode: "AL", id: "AL:HOUSTON")
        #expect(try store.licenses(in: houston, filter: LicenseFilter(serviceCodes: ["PW"])).isEmpty)
        #expect(try store.licenses(in: houston, filter: LicenseFilter(serviceCodes: ["IG"])).count == 1)
        #expect(try store.licenses(in: houston, filter: LicenseFilter(text: "utility")).count == 1)
        #expect(try store.licenses(in: houston, filter: LicenseFilter(text: "nomatch")).isEmpty)
    }

    @Test func detailResolvesSitesAndFrequencies() throws {
        let store = try Self.store()
        let detail = try #require(try store.detail(uid: 1001))
        #expect(detail.summary.callSign == "KAAA111")
        #expect(detail.sites.count == 2)
        #expect(detail.sites.first { $0.locationNumber == 2 }?.latitude == nil)
        #expect(detail.sites.first { $0.locationNumber == 1 }?.countyName == "Coffee County")
        #expect(detail.frequencies.map(\.frequencyHz) == [155_475_000, 856_012_500])
        #expect(detail.frequencies.last?.bandwidthHz != nil)
        #expect(try store.detail(uid: 999_999) == nil)
    }

    @Test func searchFindsByLicenseeCallSignAndFrequency() throws {
        let store = try Self.store()
        #expect(try store.search("coffee", scope: .licensee).map(\.uid) == [1001])
        #expect(try store.search("KAAA", scope: .callSign).map(\.uid) == [1001])
        #expect(try store.search("KAAA", scope: .licensee).isEmpty)
        let byFrequency = try store.search("856.0125", scope: .frequency)
        #expect(byFrequency.first?.frequencyHz == 856_012_500)
        #expect(byFrequency.first?.kind == .frequency)
        // .all treats a bare number as a frequency and words as license text
        #expect(try store.search("856.0125", scope: .all).contains { $0.kind == .frequency })
        #expect(try store.search("sheriff", scope: .all).contains { $0.kind == .license })
    }

    @Test func hostileSearchTextNeverThrows() throws {
        let store = try Self.store()
        for text in ["\"", "*", "AND", "OR NOT", "(", ")", "a\"b", "'; DROP TABLE licenses; --", "   ", ""] {
            _ = try store.search(text, scope: .all)
        }
        #expect(try store.counties().isEmpty == false)   // tables still intact
    }

    @Test func nearbyUsesDistanceAndSkipsSitesWithoutCoordinates() throws {
        let store = try Self.store()
        let near = try store.nearby(Coordinate(latitude: 31.3186, longitude: -85.8328), radiusKm: 5)
        #expect(near.map(\.frequency.frequencyHz) == [856_012_500])
        #expect(near.first?.callSign == "KAAA111")
        #expect((near.first?.distanceKm ?? 99) < 1)
        // Dothan (KBBB222) is roughly 60 km away: excluded at 5 km, included at 100 km.
        let wide = try store.nearby(Coordinate(latitude: 31.3186, longitude: -85.8328), radiusKm: 100)
        #expect(wide.contains { $0.callSign == "KBBB222" })
        #expect(wide.map(\.distanceKm) == wide.map(\.distanceKm).sorted())
    }

    @Test func packNewerThanTheAppIsRefused() throws {
        let (manifest, output) = try PackBuilderTests.build()
        let entry = try #require(manifest.packs.first)
        let compressed = try Data(contentsOf: output.appendingPathComponent(entry.fileName))
        let raw = try (compressed as NSData).decompressed(using: .lzfse) as Data
        let path = output.appendingPathComponent("future.sqlite")
        try raw.write(to: path)
        let db = try FrequencyStoreTestSupport.openWritable(path.path)
        try db.write { try $0.execute(sql: "UPDATE meta SET value = '99' WHERE key = 'schemaVersion'") }
        #expect(throws: PackStoreError.schemaTooNew(99)) { try FrequencyStore(path: path.path) }
    }
}

import Testing
@testable import SignalHiveCore

struct CountyNormalizerTests {
    @Test(arguments: [
        ("ST. LOUIS", "SAINT LOUIS"),
        ("ST LOUIS COUNTY", "SAINT LOUIS"),
        ("STE GENEVIEVE", "SAINTE GENEVIEVE"),
        ("DE KALB", "DEKALB"),
        ("O'BRIEN", "OBRIEN"),
        ("QUEEN ANNE'S", "QUEEN ANNES"),
        ("  east   baton rouge parish ", "EAST BATON ROUGE"),
        ("ALEXANDRIA (CITY)", "ALEXANDRIA CITY"),
        ("ANCHORAGE BOROUGH", "ANCHORAGE"),
        ("YUKON-KOYUKUK CENSUS AREA", "YUKON-KOYUKUK"),
        ("", ""),
    ]) func keys(raw: String, expected: String) {
        #expect(CountyNormalizer.key(raw) == expected)
    }

    @Test func displayNamesUseLocalSuffixConventions() {
        #expect(CountyNormalizer.displayName(key: "SAINT LOUIS", stateCode: "MO") == "St. Louis County")
        #expect(CountyNormalizer.displayName(key: "EAST BATON ROUGE", stateCode: "LA") == "East Baton Rouge Parish")
        #expect(CountyNormalizer.displayName(key: "ALEXANDRIA CITY", stateCode: "VA") == "Alexandria City")
        #expect(CountyNormalizer.displayName(key: "ANCHORAGE", stateCode: "AK") == "Anchorage")
        #expect(CountyNormalizer.displayName(key: "MCKEAN", stateCode: "PA") == "McKean County")
        #expect(CountyNormalizer.displayName(key: "COFFEE", stateCode: "AL") == "Coffee County")
    }

    @Test func countyIDIsStateScopedAndNilForBlank() {
        #expect(CountyNormalizer.countyID(raw: "Coffee", stateCode: "AL") == "AL:COFFEE")
        #expect(CountyNormalizer.countyID(raw: "  ", stateCode: "AL") == nil)
        #expect(CountyNormalizer.countyID(raw: "ST. LOUIS", stateCode: "MO")
            == CountyNormalizer.countyID(raw: "Saint Louis County", stateCode: "MO"))
    }
}

import Testing
@testable import SignalHiveCore

struct ULSFixTests {
    @Test func archiveNamesMatchFCCFilenames() {
        let expected: [ULSService: String] = [
            .lmPriv: "l_LMpriv", .lmComm: "l_LMcomm", .gmrs: "l_gmrs",
            .aircraft: "l_aircr", .amateur: "l_amat", .marine: "l_coast", .ship: "l_ship",
        ]
        #expect(expected.count == ULSService.allCases.count)
        for service in ULSService.allCases {
            let name = expected[service]!
            #expect(service.archiveName == name)
            #expect(service.completeZipURL.absoluteString
                == "https://data.fcc.gov/download/pub/uls/complete/\(name).zip")
        }
    }

    @Test func locationCoordinatesUseColumns19Through26() throws {
        // Real LO.dat row: KNNF642, Enterprise, Coffee County, AL (31°19'7.0"N 85°49'58.0"W)
        var f = Array(repeating: "", count: 51)
        f[0] = "LO"; f[1] = "1113840"; f[4] = "KNNF642"; f[8] = "1"
        f[12] = "ENTERPRISE"; f[13] = "COFFEE"; f[14] = "AL"
        f[19] = "31"; f[20] = "19"; f[21] = "7.0"; f[22] = "N"
        f[23] = "85"; f[24] = "49"; f[25] = "58.0"; f[26] = "W"
        let loc = try #require(ULSParser.parseLocation(ULSRawRecord(fields: f)))
        #expect(abs(loc.latitude - 31.31861) < 0.0001)
        #expect(abs(loc.longitude - (-85.83278)) < 0.0001)
        #expect(loc.county == "COFFEE" && loc.state == "AL" && loc.locationNumber == 1)
    }
}

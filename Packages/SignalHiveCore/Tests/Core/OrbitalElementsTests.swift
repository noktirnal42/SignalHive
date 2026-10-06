import Testing
import Foundation
@testable import SignalHiveCore

/// 2025-09-30 ISS elements. The old planner's test carried line 2 with a wrong checksum digit (5); 4 is correct.
private let issLine1 = "1 25544U 98067A   25273.56282970  .00013982  00000+0  25353-3 0  9991"
private let issLine2 = "2 25544  51.6311 178.9253 0004254  36.7694 323.3591 15.50035835533354"

/// The same with a negative first derivative and a negative B*, checksum recomputed.
private let negativeBstarLine1 = "1 25544U 98067A   25273.56282970 -.00013982  00000+0 -25353-3 0  9993"

/// Official verification-set case 88888: no international designator, a second derivative, positive exponents.
private let verLine1 = "1 88888U          80275.98708465  .00073094  13844-3  66816-4 0    87"
private let verLine2 = "2 88888  72.8435 115.9689 0086731  52.6988 110.5714 16.05824518  1058"

/// 2001-039A, 1.0027 rev/day (geosynchronous), from the same verification set.
private let geoLine1 = "1 26900U 01039A   06106.74503247  .00000045  00000-0  10000-3 0  8290"
private let geoLine2 = "2 26900   0.0164 266.5378 0003319  86.1794 182.2590  1.00273847 16981"

/// An OMM epoch ("2026-10-05T14:52:43.642848", no zone, UTC) read independently of the parser under test.
private func epoch(_ text: String) -> Date {
    let parts = text.split(separator: ".", maxSplits: 1)
    let whole = ISO8601DateFormatter().date(from: String(parts[0]) + "Z")!
    let fraction = parts.count > 1 ? Double("0." + parts[1])! : 0
    return whole.addingTimeInterval(fraction)
}

private func ommRow(_ id: Int, name: String = "TEST SAT", epoch: String = "2026-10-05T12:00:00.000000",
                    motion: Any = 14.2, eccentricity: Any = 0.001, inclination: Any = 98.7) -> [String: Any] {
    ["OBJECT_NAME": name, "NORAD_CAT_ID": id, "EPOCH": epoch, "MEAN_MOTION": motion, "ECCENTRICITY": eccentricity,
     "INCLINATION": inclination, "RA_OF_ASC_NODE": 10.0, "ARG_OF_PERICENTER": 20.0, "MEAN_ANOMALY": 30.0,
     "BSTAR": 1.0e-5, "MEAN_MOTION_DOT": 1.0e-7, "MEAN_MOTION_DDOT": 0.0]
}

private func json(_ rows: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: rows)
}

struct OrbitalElementsTests {
    @Test func ommJSONRowsParseWithEpochAndUnits() throws {
        let result = try ElementParser.parseOMMJSON(try Fixtures.data("celestrak-weather-sample.json"))
        #expect(result.rejected.isEmpty)
        #expect(result.elements.count == 3)
        let meteor = try #require(result.elements.first { $0.noradID == 59051 })
        #expect(meteor.name == "METEOR-M2 4")
        #expect(abs(meteor.epoch.timeIntervalSince(epoch("2026-10-05T14:52:43.642848"))) < 1e-6)
        #expect(meteor.meanMotionRevsPerDay == 14.22439119)
        #expect(meteor.inclinationDegrees == 98.7166)
        #expect(meteor.eccentricity == 0.00064551)
        #expect(meteor.bstar == 2.5179756e-05)
        #expect(abs(meteor.periodMinutes - 1440 / 14.22439119) < 1e-9)
    }

    @Test func sixDigitCatalogNumbersParse() throws {
        let result = try ElementParser.parseOMMJSON(try json([ommRow(100_001)]))
        #expect(result.elements.map(\.noradID) == [100_001])
    }

    @Test func badRowsAreRejectedNotFatal() throws {
        var missingMotion = ommRow(2)
        missingMotion.removeValue(forKey: "MEAN_MOTION")
        let rows = [ommRow(1), missingMotion, ommRow(3), ommRow(4, eccentricity: "NaN"), ommRow(5)]
        let result = try ElementParser.parseOMMJSON(try json(rows))
        #expect(result.elements.map(\.noradID) == [1, 3, 5])
        #expect(result.rejected.map(\.position) == [1, 3])
        #expect(result.rejected.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func duplicateNoradIDsKeepTheNewestEpoch() throws {
        let older = ommRow(7, name: "OLD", epoch: "2026-10-04T00:00:00.000000")
        let newer = ommRow(7, name: "NEW", epoch: "2026-10-05T00:00:00.000000")
        for rows in [[older, newer], [newer, older]] {
            let result = try ElementParser.parseOMMJSON(try json(rows))
            #expect(result.elements.count == 1)
            #expect(result.elements.first?.name == "NEW")
        }
    }

    @Test func eccentricityOutsideZeroToOneIsRejected() throws {
        let rows = [ommRow(1, eccentricity: 1.0), ommRow(2, eccentricity: -0.1), ommRow(3, eccentricity: 0.0)]
        let result = try ElementParser.parseOMMJSON(try json(rows))
        #expect(result.elements.map(\.noradID) == [3])
        #expect(result.rejected.count == 2)
    }

    @Test func nonsenseNumbersAreRejected() throws {
        let rows = [ommRow(1, motion: 0.0), ommRow(2, inclination: 181.0), ommRow(3, motion: "abc")]
        let result = try ElementParser.parseOMMJSON(try json(rows))
        #expect(result.elements.isEmpty)
        #expect(result.rejected.count == 3)
    }

    @Test func emptyAndHtmlBodiesAreRejectedWithAReason() throws {
        #expect(try ElementParser.parseOMMJSON(Data("[]".utf8)).elements.isEmpty)
        let html = Data("<html><body><h1>503 Service Unavailable</h1></body></html>".utf8)
        #expect(throws: ElementParser.ParseError.self) { try ElementParser.parseOMMJSON(html) }
        do {
            _ = try ElementParser.parseOMMJSON(Data("No GP data found".utf8))
            Issue.record("a plain-text body should throw")
        } catch let error as ElementParser.ParseError {
            #expect(error.message.contains("No GP data found"))
        }
        #expect(throws: ElementParser.ParseError.self) { try ElementParser.parseOMMJSON(Data("{\"error\": 1}".utf8)) }
    }

    @Test func csvParsesTheSameRowsAsJSON() throws {
        let fromJSON = try ElementParser.parseOMMJSON(try Fixtures.data("celestrak-weather-sample.json"))
        let fromCSV = ElementParser.parseOMMCSV(try Fixtures.text("celestrak-sample.csv"))
        #expect(fromCSV.rejected.isEmpty)
        #expect(fromCSV.elements.count == 3)
        for expected in fromJSON.elements {
            let actual = try #require(fromCSV.elements.first { $0.noradID == expected.noradID })
            #expect(actual == expected)
        }
    }

    @Test func csvWithoutAHeaderIsRejectedNotFatal() {
        let result = ElementParser.parseOMMCSV("not,a,header\n1,2,3\n")
        #expect(result.elements.isEmpty)
        #expect(!result.rejected.isEmpty)
        #expect(ElementParser.parseOMMCSV("").elements.isEmpty)
    }

    @Test func tleFixedColumnsParseIncludingNegativeBstar() throws {
        let iss = try #require(ElementParser.parseTLE([issLine1, issLine2].joined(separator: "\n")).elements.first)
        #expect(iss.noradID == 25544)
        #expect(iss.inclinationDegrees == 51.6311)
        #expect(iss.raanDegrees == 178.9253)
        #expect(iss.eccentricity == 0.0004254)
        #expect(iss.argumentOfPerigeeDegrees == 36.7694)
        #expect(iss.meanAnomalyDegrees == 323.3591)
        #expect(iss.meanMotionRevsPerDay == 15.50035835)
        #expect(abs(iss.bstar - 0.00025353) < 1e-12)
        #expect(abs(iss.meanMotionDot - 0.00013982) < 1e-12)
        // 25273.56282970 is day 273.56282970 of 2025: 2025-09-30 13:30:28.
        let expected = ISO8601DateFormatter().date(from: "2025-09-30T13:30:28Z")!
        #expect(abs(iss.epoch.timeIntervalSince(expected)) < 1.0)

        let negative = try #require(ElementParser.parseTLE([negativeBstarLine1, issLine2].joined(separator: "\n")).elements.first)
        #expect(abs(negative.bstar + 0.00025353) < 1e-12)
        #expect(abs(negative.meanMotionDot + 0.00013982) < 1e-12)
    }

    @Test func tleWithBlankDesignatorAndSecondDerivativeParses() throws {
        let sat = try #require(ElementParser.parseTLE([verLine1, verLine2].joined(separator: "\n")).elements.first)
        #expect(sat.noradID == 88888)
        #expect(abs(sat.meanMotionDDot - 0.13844e-3) < 1e-12)
        #expect(abs(sat.bstar - 0.66816e-4) < 1e-12)
        // 80275.98708465: 1980 is a leap year, day 275 is October 1.
        let expected = ISO8601DateFormatter().date(from: "1980-10-01T23:41:24Z")!
        #expect(abs(sat.epoch.timeIntervalSince(expected)) < 1.0)
    }

    @Test func threeLineSetsTakeTheNameFromTheLineAbove() {
        let text = "ISS (ZARYA)\n\(issLine1)\n\(issLine2)\n0 METEOR-M2 4\n\(verLine1)\n\(verLine2)\n"
        let result = ElementParser.parseTLE(text)
        #expect(result.elements.map(\.name) == ["ISS (ZARYA)", "METEOR-M2 4"])
    }

    @Test func tleWithBadChecksumIsRejected() {
        let wrong = String(issLine2.dropLast()) + "5" // the old test's digit
        let result = ElementParser.parseTLE([issLine1, wrong].joined(separator: "\n"))
        #expect(result.elements.isEmpty)
        #expect(result.rejected.count == 1)
        #expect(result.rejected.first?.reason.contains("checksum") == true)
    }

    @Test func tleWithMismatchedOrShortLinesIsRejected() {
        let other = "2 25545  51.6311 178.9253 0004254  36.7694 323.3591 15.50035835533355"
        #expect(ElementParser.parseTLE([issLine1, other].joined(separator: "\n")).elements.isEmpty)
        #expect(ElementParser.parseTLE([issLine1, String(issLine2.prefix(40))].joined(separator: "\n")).elements.isEmpty)
        #expect(ElementParser.parseTLE("garbage\nmore garbage").elements.isEmpty)
    }

    @Test func periodAndDeepSpaceFlag() throws {
        let iss = try #require(ElementParser.parseTLE([issLine1, issLine2].joined(separator: "\n")).elements.first)
        #expect(abs(iss.periodMinutes - 92.9) < 0.1)
        #expect(!iss.isDeepSpace)
        let geo = try #require(ElementParser.parseTLE([geoLine1, geoLine2].joined(separator: "\n")).elements.first)
        #expect(geo.isDeepSpace)
    }

    @Test func elementsRoundTripThroughJSON() throws {
        let original = try ElementParser.parseOMMJSON(try Fixtures.data("celestrak-weather-sample.json")).elements
        let decoded = try JSONDecoder().decode([OrbitalElements].self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

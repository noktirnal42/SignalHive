import Testing
import Foundation
@testable import SignalHiveCore

struct AviationFormatTests {
    @Test func altitudesSwitchToFlightLevelsAtEighteenThousand() {
        #expect(AviationFormat.altitude(35_000) == "FL350")
        #expect(AviationFormat.altitude(18_000) == "FL180")
        #expect(AviationFormat.altitude(17_999) == "17,999 ft")
        #expect(AviationFormat.altitude(500) == "500 ft")
        #expect(AviationFormat.altitude(-200) == "-200 ft")
        #expect(AviationFormat.altitude(nil) == "\u{2014}")
        #expect(AviationFormat.altitude(35_000, onGround: true) == "GND")
        #expect(AviationFormat.altitude(4_050) == "4,050 ft")
        #expect(AviationFormat.altitude(9_000) == "9,000 ft")
    }

    @Test func mapLabelsAreShort() {
        #expect(AviationFormat.altitudeLabel(3_200) == "3,200")
        #expect(AviationFormat.altitudeLabel(36_000) == "FL360")
        #expect(AviationFormat.altitudeLabel(nil) == "\u{2014}")
        #expect(AviationFormat.altitudeLabel(0, onGround: true) == "GND")
    }

    @Test func speedsHeadingsAndClimbRates() {
        #expect(AviationFormat.speed(450.4) == "450 kt")
        #expect(AviationFormat.speed(nil) == "\u{2014}")
        #expect(AviationFormat.track(5) == "005\u{00B0}")
        #expect(AviationFormat.track(359.6) == "000\u{00B0}")
        #expect(AviationFormat.verticalRate(1_500) == "+1,500 fpm")
        #expect(AviationFormat.verticalRate(-800) == "-800 fpm")
        #expect(AviationFormat.verticalRate(40) == "level")
        #expect(AviationFormat.verticalRate(nil) == "\u{2014}")
    }

    @Test func distancesAndAges() {
        #expect(AviationFormat.distance(12.34) == "12.3 NM")
        #expect(AviationFormat.distance(123.6) == "124 NM")
        #expect(AviationFormat.distance(nil) == "\u{2014}")
        #expect(AviationFormat.age(3) == "3 s")
        #expect(AviationFormat.age(130) == "2 min")
        #expect(AviationFormat.age(3_900) == "1 h 5 min")
        #expect(AviationFormat.age(7_200) == "2 h")
        #expect(AviationFormat.age(-5) == "0 s")
    }

    @Test func coordinatesShowHemispheres() {
        #expect(AviationFormat.coordinate(GeoCoordinate(latitude: 40.1234, longitude: -100.5)) == "40.1234\u{00B0}N 100.5000\u{00B0}W")
        #expect(AviationFormat.coordinate(GeoCoordinate(latitude: -33.9, longitude: 151.2)) == "33.9000\u{00B0}S 151.2000\u{00B0}E")
    }

    @Test func thousandsAreGrouped() {
        #expect(AviationFormat.grouped(0) == "0")
        #expect(AviationFormat.grouped(999) == "999")
        #expect(AviationFormat.grouped(1_000) == "1,000")
        #expect(AviationFormat.grouped(1_234_567) == "1,234,567")
        #expect(AviationFormat.grouped(-12_345) == "-12,345")
    }
}

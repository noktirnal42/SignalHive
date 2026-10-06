import Testing
import Foundation
@testable import SignalHiveCore

private let kmPerAU = 149_597_870.7

private func utc(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

struct SunPositionTests {
    /// Meeus, Astronomical Algorithms, example 25.a: 1992 October 13, 0h TD. Apparent right ascension 198.38083
    /// degrees, declination -7.78507 degrees, distance 0.99766 AU. (UTC for TD is 59 s off, 0.0007 degrees of solar
    /// motion, far inside the tolerances.)
    @Test func meeusExample25a() {
        let sun = SunPosition.vector(at: utc("1992-10-13T00:00:00Z"))
        var rightAscension = atan2(sun.y, sun.x) * 180 / .pi
        if rightAscension < 0 { rightAscension += 360 }
        let declination = asin(sun.z / sun.length) * 180 / .pi
        #expect(abs(rightAscension - 198.38083) < 0.02, "RA \(rightAscension)")
        #expect(abs(declination - (-7.78507)) < 0.02, "Dec \(declination)")
        #expect(abs(sun.length / kmPerAU - 0.99766) < 0.0005, "distance \(sun.length / kmPerAU) AU")
    }

    @Test func sunDistanceStaysBetweenPerihelionAndAphelion() {
        var day = utc("2026-01-01T00:00:00Z")
        for _ in 0..<365 {
            let au = SunPosition.vector(at: day).length / kmPerAU
            #expect(au > 0.9830 && au < 1.0170, "\(au) AU on \(day)")
            day.addTimeInterval(86_400)
        }
    }

    @Test func sunIsHighAtNoonOnTheSummerSolsticeAtTheTropic() {
        let elevation = SunPosition.elevationDegrees(from: Observer(latitudeDegrees: 23.44, longitudeDegrees: 0),
                                                     at: utc("2026-06-21T12:00:00Z"))
        #expect(abs(elevation - 90) < 1, "elevation \(elevation)")
    }

    @Test func sunIsBelowTheHorizonAtLocalMidnight() {
        // Solar midnight at 109.4 W falls near 07:17 UTC.
        let elevation = SunPosition.elevationDegrees(from: Observer(latitudeDegrees: 35.25, longitudeDegrees: -109.44),
                                                     at: utc("2026-10-05T07:17:00Z"))
        #expect(elevation < -30, "elevation \(elevation)")
        let noon = SunPosition.elevationDegrees(from: Observer(latitudeDegrees: 35.25, longitudeDegrees: -109.44),
                                                at: utc("2026-10-05T19:17:00Z"))
        #expect(noon > 40, "noon elevation \(noon)")
    }

    @Test func elevationIsAlwaysBetweenMinusAndPlus90() {
        var rng = SeededGenerator(seed: 11)
        for _ in 0..<300 {
            let observer = Observer(latitudeDegrees: Double.random(in: -90...90, using: &rng),
                                    longitudeDegrees: Double.random(in: -180...180, using: &rng))
            let date = Date(timeIntervalSince1970: Double.random(in: 1_700_000_000...1_900_000_000, using: &rng))
            let elevation = SunPosition.elevationDegrees(from: observer, at: date)
            #expect(elevation >= -90 && elevation <= 90 && elevation.isFinite)
        }
    }

    @Test func satelliteBehindTheEarthIsInShadow() {
        let sun = Vector3(149_597_870.7, 0, 0)
        #expect(!SunPosition.isSunlit(satellite: Vector3(-7000, 0, 0), sun: sun))
        #expect(SunPosition.isSunlit(satellite: Vector3(7000, 0, 0), sun: sun))
        #expect(SunPosition.isSunlit(satellite: Vector3(0, 7000, 0), sun: sun))
        // Just inside and just outside the Earth's shadow cylinder.
        #expect(!SunPosition.isSunlit(satellite: Vector3(-7000, 6370, 0), sun: sun))
        #expect(SunPosition.isSunlit(satellite: Vector3(-7000, 6390, 0), sun: sun))
    }
}

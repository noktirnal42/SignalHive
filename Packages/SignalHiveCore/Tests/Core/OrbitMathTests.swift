import Testing
import Foundation
@testable import SignalHiveCore

/// A fixed-seed generator so "random" observers are the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func utc(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

/// Difference of two longitudes in degrees, so 180 and -180 count as the same meridian.
private func longitudeDifference(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return abs(d)
}

struct OrbitMathTests {
    @Test func julianDateOfJ2000() {
        #expect(TimeScales.julianDate(utc("2000-01-01T12:00:00Z")) == 2_451_545.0)
    }

    @Test func gmstAtJ2000() {
        // 280.46061837 degrees, the standard value at J2000.
        let gmst = TimeScales.gmstRadians(utc("2000-01-01T12:00:00Z"))
        #expect(abs(gmst - 4.894961212823756) < 1e-9)
    }

    @Test func gmstIsInZeroToTwoPi() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<1000 {
            let date = Date(timeIntervalSince1970: Double.random(in: -2_000_000_000...4_000_000_000, using: &rng))
            let gmst = TimeScales.gmstRadians(date)
            #expect(gmst >= 0 && gmst < 2 * .pi, "gmst \(gmst) for \(date)")
        }
    }

    @Test func ecefOfEquatorObserverAtSeaLevel() {
        let p = Geodesy.ecef(of: Observer(latitudeDegrees: 0, longitudeDegrees: 0))
        #expect(abs(p.x - 6378.137) < 1e-9)
        #expect(abs(p.y) < 1e-9)
        #expect(abs(p.z) < 1e-9)
    }

    @Test func ecefOfPole() {
        let p = Geodesy.ecef(of: Observer(latitudeDegrees: 90, longitudeDegrees: 0))
        #expect(abs(p.z - 6356.752314245) < 1e-6)
        #expect(abs(p.x) < 1e-6)
    }

    @Test func geodeticRoundTrip() {
        var rng = SeededGenerator(seed: 42)
        var cases: [(Double, Double, Double)] = [
            (89.9999, 10, 0), (-89.9999, -170, 0), (0, 180, 0), (0, -180, 0), (45, 180, 1200), (-45, -180, 4000),
        ]
        for _ in 0..<194 {
            cases.append((Double.random(in: -90...90, using: &rng), Double.random(in: -180...180, using: &rng),
                          Double.random(in: -400...9000, using: &rng)))
        }
        for (lat, lon, altMeters) in cases {
            let ecef = Geodesy.ecef(of: Observer(latitudeDegrees: lat, longitudeDegrees: lon, altitudeMeters: altMeters))
            let back = Geodesy.geodetic(fromECEF: ecef)
            #expect(abs(back.latitudeDegrees - lat) < 1e-9, "lat \(lat) came back \(back.latitudeDegrees)")
            #expect(longitudeDifference(back.longitudeDegrees, lon) < 1e-9, "lon \(lon) came back \(back.longitudeDegrees)")
            #expect(abs(back.altitudeKM - altMeters / 1000) < 1e-9, "alt \(altMeters) m came back \(back.altitudeKM * 1000)")
        }
    }

    @Test func observerValidity() {
        #expect(Observer(latitudeDegrees: 35, longitudeDegrees: -109).isValid)
        #expect(Observer(latitudeDegrees: 90, longitudeDegrees: 180).isValid)
        #expect(Observer(latitudeDegrees: -90, longitudeDegrees: -180).isValid)
        #expect(!Observer(latitudeDegrees: 91, longitudeDegrees: 0).isValid)
        #expect(!Observer(latitudeDegrees: .nan, longitudeDegrees: 0).isValid)
        #expect(!Observer(latitudeDegrees: 0, longitudeDegrees: 181).isValid)
        #expect(!Observer(latitudeDegrees: 0, longitudeDegrees: 0, altitudeMeters: .infinity).isValid)
    }

    @Test func vectorArithmetic() {
        let a = Vector3(1, 2, 3), b = Vector3(4, 5, 6)
        #expect(a + b == Vector3(5, 7, 9))
        #expect(b - a == Vector3(3, 3, 3))
        #expect(a * 2 == Vector3(2, 4, 6))
        #expect(a.dot(b) == 32)
        #expect(a.cross(b) == Vector3(-3, 6, -3))
        #expect(abs(Vector3(3, 4, 12).length - 13) < 1e-15)
    }

    @Test func observerFromACoordinate() {
        let o = Observer(GeoCoordinate(latitude: 35.25, longitude: -109.44), altitudeMeters: 1700)
        #expect(o.latitudeDegrees == 35.25 && o.longitudeDegrees == -109.44 && o.altitudeMeters == 1700)
    }
}

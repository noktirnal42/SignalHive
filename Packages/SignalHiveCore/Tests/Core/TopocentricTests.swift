import Testing
import Foundation
@testable import SignalHiveCore

/// Observer-frame samples from the oracle (computed in python by rotation matrices, independent of the Swift code).
private struct LookOracle {
    struct Sample { let minutes, az, el, rangeKM, rangeRateKMS: Double }
    let name: String
    let elements: OrbitalElements
    let observer: Observer
    let samples: [Sample]

    static func load() throws -> [LookOracle] {
        let root = try #require(try Fixtures.json("sgp4-oracle.json") as? [String: Any])
        let cases = try OracleCase.load()
        let raw = try #require(root["cases"] as? [[String: Any]])
        return try raw.compactMap { entry in
            guard let look = entry["look"] as? [String: Any] else { return nil }
            let name = entry["name"] as! String
            let o = look["observer"] as! [Double]
            let samples = (look["samples"] as! [[String: Any]]).map {
                Sample(minutes: $0["minutes"] as! Double, az: $0["az"] as! Double, el: $0["el"] as! Double,
                       rangeKM: $0["rangeKM"] as! Double, rangeRateKMS: $0["rangeRateKMS"] as! Double)
            }
            let match = try #require(cases.first { $0.name == name })
            return LookOracle(name: name, elements: match.elements,
                              observer: Observer(latitudeDegrees: o[0], longitudeDegrees: o[1], altitudeMeters: o[2]),
                              samples: samples)
        }
    }
}

/// A state fixed in the Earth-fixed frame at an Earth-fixed position, expressed in TEME at `date` (so the
/// range-rate to a ground observer is exactly zero).
private func stationaryState(ecef: Vector3, at date: Date) -> StateVector {
    let gmst = TimeScales.gmstRadians(date)
    let c = cos(gmst), s = sin(gmst)
    let r = Vector3(c * ecef.x - s * ecef.y, s * ecef.x + c * ecef.y, ecef.z)
    let w = WGS84.earthRotationRadPerSec
    return StateVector(position: r, velocity: Vector3(-w * r.y, w * r.x, 0))
}

struct TopocentricTests {
    @Test func matchesTheIndependentOracle() throws {
        let oracles = try LookOracle.load()
        #expect(oracles.count >= 2)
        var compared = 0
        for oracle in oracles {
            let propagator = try SGP4Propagator(oracle.elements)
            for sample in oracle.samples {
                let date = oracle.elements.epoch.addingTimeInterval(sample.minutes * 60)
                let state = try propagator.state(minutesSinceEpoch: sample.minutes)
                let look = Topocentric.look(state, at: date, from: oracle.observer)
                let tag = "\(oracle.name) at \(sample.minutes) min"
                #expect(abs(look.azimuthDegrees - sample.az) < 0.01 || abs(look.azimuthDegrees - sample.az) > 359.99, "\(tag): az \(look.azimuthDegrees) vs \(sample.az)")
                #expect(abs(look.elevationDegrees - sample.el) < 0.01, "\(tag): el \(look.elevationDegrees) vs \(sample.el)")
                #expect(abs(look.rangeKM - sample.rangeKM) < 0.01, "\(tag): range \(look.rangeKM) vs \(sample.rangeKM)")
                #expect(abs(look.rangeRateKMPerSec - sample.rangeRateKMS) < 1e-5, "\(tag): range-rate \(look.rangeRateKMPerSec) vs \(sample.rangeRateKMS)")
                #expect(look.time == date)
                compared += 1
            }
        }
        #expect(compared >= 250)
    }

    @Test func rangeRateIsTheDerivativeOfRange() throws {
        let iss = try #require(try LookOracle.load().first { $0.name == "iss-2025-09-30" })
        let propagator = try SGP4Propagator(iss.elements)
        var rng = SeededGenerator(seed: 99)
        for _ in 0..<20 {
            let minutes = Double.random(in: 0...1440, using: &rng)
            let date = iss.elements.epoch.addingTimeInterval(minutes * 60)
            let at = Topocentric.look(try propagator.state(at: date), at: date, from: iss.observer)
            let before = date.addingTimeInterval(-0.5), after = date.addingTimeInterval(0.5)
            let rangeBefore = Topocentric.look(try propagator.state(at: before), at: before, from: iss.observer).rangeKM
            let rangeAfter = Topocentric.look(try propagator.state(at: after), at: after, from: iss.observer).rangeKM
            #expect(abs((rangeAfter - rangeBefore) - at.rangeRateKMPerSec) < 1e-4,
                    "at \(minutes) min: finite difference \(rangeAfter - rangeBefore) vs \(at.rangeRateKMPerSec) km/s")
        }
    }

    @Test func zenithPassHasElevation90AndDefinedAzimuth() {
        let observer = Observer(latitudeDegrees: 35, longitudeDegrees: -109, altitudeMeters: 1500)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let overhead = Observer(latitudeDegrees: 35, longitudeDegrees: -109, altitudeMeters: 1500 + 500_000)
        let state = stationaryState(ecef: Geodesy.ecef(of: overhead), at: date)
        let look = Topocentric.look(state, at: date, from: observer)
        #expect(abs(look.elevationDegrees - 90) < 1e-6)
        #expect(look.azimuthDegrees.isFinite && (0..<360).contains(look.azimuthDegrees))
        #expect(abs(look.rangeKM - 500) < 1e-6)
        #expect(abs(look.rangeRateKMPerSec) < 1e-9)
    }

    @Test func dopplerSignAndMagnitude() {
        let carrier = 137_900_000.0
        // Receding at 7 km/s: the received frequency is lower, by f * v / c = 3.22 kHz.
        let receding = Topocentric.dopplerShiftHz(carrierHz: carrier, rangeRateKMPerSec: 7)
        #expect(abs(receding + 3219.5) < 1)
        let approaching = Topocentric.dopplerShiftHz(carrierHz: carrier, rangeRateKMPerSec: -7)
        #expect(abs(approaching - 3219.5) < 1)
        #expect(Topocentric.dopplerShiftHz(carrierHz: carrier, rangeRateKMPerSec: 0) == 0)
        #expect(Topocentric.receivedFrequencyHz(carrierHz: carrier, rangeRateKMPerSec: 7) == carrier + receding)
    }

    @Test func azimuthIsAlwaysInZeroTo360() {
        var rng = SeededGenerator(seed: 5)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<500 {
            let direction = Vector3(Double.random(in: -1...1, using: &rng), Double.random(in: -1...1, using: &rng),
                                    Double.random(in: -1...1, using: &rng))
            guard direction.length > 0.1 else { continue }
            let position = direction * (7000 / direction.length)
            let observer = Observer(latitudeDegrees: Double.random(in: -90...90, using: &rng),
                                    longitudeDegrees: Double.random(in: -180...180, using: &rng))
            let look = Topocentric.look(StateVector(position: position, velocity: Vector3(1, 2, 3)), at: date, from: observer)
            #expect(look.azimuthDegrees >= 0 && look.azimuthDegrees < 360, "azimuth \(look.azimuthDegrees)")
        }
    }

    @Test func observerAtThePoleDoesNotProduceNaN() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        for latitude in [90.0, -90.0, 89.9999, -89.9999] {
            for position in [Vector3(7000, 0, 0), Vector3(0, 0, 7000), Vector3(0, 0, -7000), Vector3(-3000, 4000, 4500)] {
                let state = StateVector(position: position, velocity: Vector3(0, 7.5, 0))
                let look = Topocentric.look(state, at: date, from: Observer(latitudeDegrees: latitude, longitudeDegrees: 0))
                let values = [look.azimuthDegrees, look.elevationDegrees, look.rangeKM, look.rangeRateKMPerSec]
                #expect(values.allSatisfy { $0.isFinite }, "lat \(latitude), position \(position): \(values)")
                #expect(look.azimuthDegrees >= 0 && look.azimuthDegrees < 360)
            }
        }
    }
}

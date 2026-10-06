import Testing
import Foundation
@testable import SignalHiveCore

/// One case of `sgp4-oracle.json`: python-sgp4 output (AFSPC mode, WGS-72) for an element set, checked at load against
/// the official C++ reference output, so a mismatch here is the Swift port's fault.
struct OracleCase {
    struct Sample {
        let minutes: Double
        let r: [Double]
        let v: [Double]
    }
    let name: String
    let noradID: Int
    let elements: OrbitalElements
    let periodMinutes: Double
    let samples: [Sample]
    let errorCode: Int?
    let errorMinutes: Double?

    static func load() throws -> [OracleCase] {
        let root = try #require(try Fixtures.json("sgp4-oracle.json") as? [String: Any])
        let raw = try #require(root["cases"] as? [[String: Any]])
        return try raw.map { entry in
            let omm = try #require(entry["omm"] as? [String: Any])
            let parsed = try ElementParser.parseOMMJSON(try JSONSerialization.data(withJSONObject: [omm]))
            let elements = try #require(parsed.elements.first, "oracle case \(entry["name"] ?? "?") did not parse: \(parsed.rejected)")
            let samples = (entry["samples"] as? [[String: Any]] ?? []).map {
                Sample(minutes: $0["minutes"] as! Double, r: $0["r"] as! [Double], v: $0["v"] as! [Double])
            }
            return OracleCase(name: entry["name"] as! String, noradID: entry["noradID"] as! Int, elements: elements,
                              periodMinutes: entry["periodMinutes"] as! Double, samples: samples,
                              errorCode: entry["error"] as? Int, errorMinutes: entry["errorMinutes"] as? Double)
        }
    }
}

struct SGP4Tests {
    @Test func nearEarthCasesMatchTheOracle() throws {
        let cases = try OracleCase.load().filter { $0.periodMinutes < 225 && $0.errorCode == nil }
        #expect(cases.count >= 7)
        for oracle in cases {
            let propagator = try SGP4Propagator(oracle.elements)
            for sample in oracle.samples {
                let state = try propagator.state(minutesSinceEpoch: sample.minutes)
                let dr = [state.position.x - sample.r[0], state.position.y - sample.r[1], state.position.z - sample.r[2]]
                let dv = [state.velocity.x - sample.v[0], state.velocity.y - sample.v[1], state.velocity.z - sample.v[2]]
                #expect(dr.allSatisfy { abs($0) < 1e-6 }, "\(oracle.name) at \(sample.minutes) min: position off by \(dr) km")
                #expect(dv.allSatisfy { abs($0) < 1e-9 }, "\(oracle.name) at \(sample.minutes) min: velocity off by \(dv) km/s")
            }
        }
    }

    @Test func deepSpaceCasesAreRefusedExplicitly() throws {
        let cases = try OracleCase.load().filter { $0.periodMinutes >= 225 }
        #expect(cases.count >= 10)
        for oracle in cases {
            do {
                _ = try SGP4Propagator(oracle.elements)
                Issue.record("\(oracle.name) (period \(oracle.periodMinutes) min) should be refused")
            } catch let error as SGP4Error {
                guard case .unsupportedDeepSpace = error else {
                    Issue.record("\(oracle.name) threw \(error), expected unsupportedDeepSpace")
                    continue
                }
            }
        }
    }

    /// The oracle's failure codes: 1 mean elements out of range, 6 decayed (the others are deep space only).
    @Test func decayedCasesThrowAtTheOracleMinute() throws {
        let cases = try OracleCase.load().filter { $0.periodMinutes < 225 && $0.errorCode != nil }
        #expect(cases.count >= 3)
        for oracle in cases {
            let propagator = try SGP4Propagator(oracle.elements)
            for sample in oracle.samples { // the file keeps only the samples before the failure
                _ = try propagator.state(minutesSinceEpoch: sample.minutes)
            }
            let code = try #require(oracle.errorCode)
            let expected: SGP4Error = code == 6 ? .decayed : .meanElementsOutOfRange
            let minute = try #require(oracle.errorMinutes)
            #expect(throws: expected, "\(oracle.name) at \(minute) min") {
                _ = try propagator.state(minutesSinceEpoch: minute)
            }
        }
    }

    @Test func issAltitudeIsPlausible() throws {
        let iss = try #require(try OracleCase.load().first { $0.name == "iss-2025-09-30" })
        let state = try SGP4Propagator(iss.elements).state(minutesSinceEpoch: 0)
        #expect((6730...6830).contains(state.position.length), "radius \(state.position.length) km")
        #expect((7.5...7.8).contains(state.velocity.length), "speed \(state.velocity.length) km/s")
    }

    @Test func stateAtADateIsTheSameAsStateAtThoseMinutes() throws {
        let iss = try #require(try OracleCase.load().first { $0.name == "iss-2025-09-30" })
        let propagator = try SGP4Propagator(iss.elements)
        let byMinutes = try propagator.state(minutesSinceEpoch: 90)
        let byDate = try propagator.state(at: iss.elements.epoch.addingTimeInterval(90 * 60))
        #expect(byMinutes == byDate)
        #expect(propagator.epoch == iss.elements.epoch)
    }

    @Test func nonFiniteElementsThrow() throws {
        var elements = try #require(try OracleCase.load().first { $0.name == "iss-2025-09-30" }).elements
        elements.meanMotionRevsPerDay = .nan
        #expect(throws: SGP4Error.nonFiniteInput) { try SGP4Propagator(elements) }
        elements.meanMotionRevsPerDay = 15.5
        elements.eccentricity = .infinity
        #expect(throws: SGP4Error.nonFiniteInput) { try SGP4Propagator(elements) }
        let good = try SGP4Propagator(try #require(try OracleCase.load().first { $0.name == "iss-2025-09-30" }).elements)
        #expect(throws: SGP4Error.nonFiniteInput) { try good.state(minutesSinceEpoch: .nan) }
    }

    @Test func eccentricityAtOrAboveOneIsRefusedAtInit() throws {
        var elements = try #require(try OracleCase.load().first { $0.name == "iss-2025-09-30" }).elements
        elements.eccentricity = 1.2
        #expect(throws: SGP4Error.meanElementsOutOfRange) { try SGP4Propagator(elements) }
    }

    @Test func propagationIsDeterministicAndReentrant() async throws {
        let iss = try #require(try OracleCase.load().first { $0.name == "iss-2025-09-30" })
        let propagator = try SGP4Propagator(iss.elements)
        let reference = try propagator.state(minutesSinceEpoch: 300)
        let results = await withTaskGroup(of: StateVector?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? propagator.state(minutesSinceEpoch: 300) }
            }
            var all: [StateVector?] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == reference })
    }
}

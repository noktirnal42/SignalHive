import Testing
import Foundation
@testable import SignalHiveCore

/// Expected passes from the oracle: a 1-second brute-force search, cross-checked against skyfield (see
/// script/verify_passes_skyfield.py).
private struct PassOracle {
    struct Expected {
        let aos, tca, los: Date
        let maxEl: Double
        let startsBeforeWindow, endsAfterWindow: Bool
        var isComplete: Bool { !startsBeforeWindow && !endsAfterWindow }
    }
    struct Entry {
        let observer: Observer
        let from, through: Date
        let minElevation: Double
        let failureMinutes: Double?
        let list: [Expected]
    }
    let name: String
    let elements: OrbitalElements
    let entries: [Entry]

    static func load() throws -> [PassOracle] {
        let root = try #require(try Fixtures.json("sgp4-oracle.json") as? [String: Any])
        let cases = try OracleCase.load()
        let raw = try #require(root["cases"] as? [[String: Any]])
        return try raw.compactMap { entry in
            guard let passes = entry["passes"] as? [[String: Any]] else { return nil }
            let name = entry["name"] as! String
            let match = try #require(cases.first { $0.name == name })
            let entries = passes.map { p -> Entry in
                let o = p["observer"] as! [Double]
                let list = (p["list"] as! [[String: Any]]).map { q in
                    Expected(aos: ElementParser.parseEpoch(q["aos"] as! String)!, tca: ElementParser.parseEpoch(q["tca"] as! String)!,
                             los: ElementParser.parseEpoch(q["los"] as! String)!, maxEl: q["maxEl"] as! Double,
                             startsBeforeWindow: q["startsBeforeWindow"] as! Bool, endsAfterWindow: q["endsAfterWindow"] as! Bool)
                }
                return Entry(observer: Observer(latitudeDegrees: o[0], longitudeDegrees: o[1], altitudeMeters: o[2]),
                             from: ElementParser.parseEpoch(p["from"] as! String)!,
                             through: ElementParser.parseEpoch(p["through"] as! String)!,
                             minElevation: p["minElevation"] as! Double, failureMinutes: p["failureMinutes"] as? Double, list: list)
            }
            return PassOracle(name: name, elements: match.elements, entries: entries)
        }
    }
}

private func oracleElements(_ name: String) throws -> OrbitalElements {
    try #require(try OracleCase.load().first { $0.name == name }).elements
}

struct PassPredictorTests {
    @Test func matchesTheIndependentPredictor() throws {
        let oracles = try PassOracle.load().filter { $0.name != "ver-28872" }
        #expect(oracles.count == 3)
        var compared = 0
        for oracle in oracles {
            for entry in oracle.entries {
                let result = PassPredictor(minimumElevationDegrees: entry.minElevation)
                    .passes(for: oracle.elements, observer: entry.observer, from: entry.from, through: entry.through)
                #expect(result.problem == nil)
                let tag = "\(oracle.name) at \(entry.observer.latitudeDegrees), min \(entry.minElevation)"
                #expect(result.passes.count == entry.list.count, "\(tag): \(result.passes.count) passes, oracle \(entry.list.count)")
                guard result.passes.count == entry.list.count else { continue }
                for (pass, expected) in zip(result.passes, entry.list) {
                    #expect(abs(pass.aos.timeIntervalSince(expected.aos)) < 2, "\(tag): AOS \(pass.aos) vs \(expected.aos)")
                    #expect(abs(pass.los.timeIntervalSince(expected.los)) < 2, "\(tag): LOS \(pass.los) vs \(expected.los)")
                    #expect(abs(pass.tca.timeIntervalSince(expected.tca)) < 5, "\(tag): TCA \(pass.tca) vs \(expected.tca)")
                    #expect(abs(pass.maxElevationDegrees - expected.maxEl) < 0.1, "\(tag): max el \(pass.maxElevationDegrees) vs \(expected.maxEl)")
                    #expect(pass.startsBeforeWindow == expected.startsBeforeWindow && pass.endsAfterWindow == expected.endsAfterWindow, "\(tag): window flags")
                    compared += 1
                }
            }
        }
        #expect(compared >= 150)
    }

    @Test func edgesSitAtTheThreshold() throws {
        let oracle = try #require(try PassOracle.load().first { $0.name == "iss-2025-09-30" })
        for entry in oracle.entries {
            let result = PassPredictor(minimumElevationDegrees: entry.minElevation)
                .passes(for: oracle.elements, observer: entry.observer, from: entry.from, through: entry.through)
            for pass in result.passes where !pass.startsBeforeWindow && !pass.endsAfterWindow {
                let first = try #require(pass.track.first), last = try #require(pass.track.last)
                #expect(abs(first.elevationDegrees - entry.minElevation) < 0.02, "AOS elevation \(first.elevationDegrees)")
                #expect(abs(last.elevationDegrees - entry.minElevation) < 0.02, "LOS elevation \(last.elevationDegrees)")
            }
        }
    }

    @Test func passOrderingProperties() throws {
        let oracle = try #require(try PassOracle.load().first { $0.name == "meteor-m2-4" })
        let entry = try #require(oracle.entries.first)
        let result = PassPredictor().passes(for: oracle.elements, observer: entry.observer, from: entry.from, through: entry.through)
        #expect(!result.passes.isEmpty)
        var previousAOS = Date.distantPast
        for pass in result.passes {
            #expect(pass.aos < pass.tca && pass.tca < pass.los)
            #expect(pass.aos > previousAOS)
            previousAOS = pass.aos
            #expect(pass.track.first?.time == pass.aos && pass.track.last?.time == pass.los)
            for (a, b) in zip(pass.track, pass.track.dropFirst()) {
                let gap = b.time.timeIntervalSince(a.time)
                #expect(gap > 0 && gap <= 5.0 + 1e-6, "track gap \(gap) s")
            }
            #expect(pass.track.allSatisfy { $0.elevationDegrees >= 5 - 0.05 })
            #expect(pass.track.map(\.elevationDegrees).max()! <= pass.maxElevationDegrees + 0.01)
            #expect(pass.id == "\(pass.noradID)-\(Int(pass.aos.timeIntervalSince1970))")
            #expect(abs(pass.duration - pass.los.timeIntervalSince(pass.aos)) < 1e-9)
            #expect(pass.elementEpoch == oracle.elements.epoch)
            #expect(pass.minRangeKM > 0 && pass.minRangeKM <= (pass.track.map(\.rangeKM).min() ?? 0) + 1e-9)
            #expect((0..<360).contains(pass.aosAzimuthDegrees) && (0..<360).contains(pass.tcaAzimuthDegrees) && (0..<360).contains(pass.losAzimuthDegrees))
        }
    }

    @Test func passInProgressAtWindowStartIsTruncated() throws {
        let oracle = try #require(try PassOracle.load().first { $0.name == "iss-2025-09-30" })
        let entry = try #require(oracle.entries.first { $0.minElevation == 5 })
        let expected = try #require(entry.list.first { $0.isComplete && $0.maxEl > 30 })
        let window = expected.tca
        let result = PassPredictor().passes(for: oracle.elements, observer: entry.observer, from: window,
                                            through: window.addingTimeInterval(3 * 3600))
        let first = try #require(result.passes.first)
        #expect(first.startsBeforeWindow)
        #expect(first.aos == window)
        #expect(!first.endsAfterWindow)
        #expect(abs(first.los.timeIntervalSince(expected.los)) < 2)
        #expect(first.track.first?.time == window)
    }

    @Test func passStillUpAtWindowEndIsTruncated() throws {
        let oracle = try #require(try PassOracle.load().first { $0.name == "iss-2025-09-30" })
        let entry = try #require(oracle.entries.first { $0.minElevation == 5 })
        let expected = try #require(entry.list.first { $0.isComplete && $0.maxEl > 30 })
        let end = expected.tca
        let result = PassPredictor().passes(for: oracle.elements, observer: entry.observer,
                                            from: end.addingTimeInterval(-3 * 3600), through: end)
        let last = try #require(result.passes.last)
        #expect(last.endsAfterWindow)
        #expect(last.los == end)
        #expect(!last.startsBeforeWindow)
        #expect(abs(last.aos.timeIntervalSince(expected.aos)) < 2)
    }

    @Test func polarObserverStillWorks() throws {
        let meteor = try oracleElements("meteor-m2-4")
        let from = meteor.epoch
        for latitude in [89.99, -89.99] {
            let result = PassPredictor().passes(for: meteor, observer: Observer(latitudeDegrees: latitude, longitudeDegrees: 0),
                                                from: from, through: from.addingTimeInterval(3 * 86_400))
            #expect(result.problem == nil)
            #expect(result.passes.count > 20, "a polar orbiter passes the pole every orbit, got \(result.passes.count)")
            #expect(result.passes.map(\.aos) == result.passes.map(\.aos).sorted())
            for pass in result.passes {
                let values = [pass.maxElevationDegrees, pass.tcaAzimuthDegrees, pass.minRangeKM, pass.sunElevationAtTCADegrees]
                #expect(values.allSatisfy { $0.isFinite })
            }
        }
    }

    @Test func antimeridianObserverWorks() throws {
        let iss = try oracleElements("iss-2025-09-30")
        let from = iss.epoch, through = iss.epoch.addingTimeInterval(2 * 86_400)
        let east = PassPredictor().passes(for: iss, observer: Observer(latitudeDegrees: 20, longitudeDegrees: 180), from: from, through: through)
        let west = PassPredictor().passes(for: iss, observer: Observer(latitudeDegrees: 20, longitudeDegrees: -180), from: from, through: through)
        #expect(!east.passes.isEmpty)
        #expect(east.passes.count == west.passes.count)
        for (a, b) in zip(east.passes, west.passes) {
            #expect(abs(a.aos.timeIntervalSince(b.aos)) < 1e-6)
            #expect(abs(a.los.timeIntervalSince(b.los)) < 1e-6)
            #expect(abs(a.maxElevationDegrees - b.maxElevationDegrees) < 1e-6)
        }
    }

    @Test func satelliteThatNeverRisesReturnsNoPassesAndNoProblem() throws {
        // The ISS never gets above 51.6 degrees of latitude, so the pole never sees it.
        let iss = try oracleElements("iss-2025-09-30")
        let result = PassPredictor().passes(for: iss, observer: Observer(latitudeDegrees: 89.99, longitudeDegrees: 0),
                                            from: iss.epoch, through: iss.epoch.addingTimeInterval(3 * 86_400))
        #expect(result.passes.isEmpty)
        #expect(result.problem == nil)
    }

    @Test func satelliteThatDecaysMidWindowKeepsEarlierPassesAndReportsTheProblem() throws {
        let oracle = try #require(try PassOracle.load().first { $0.name == "ver-28872" })
        let entry = try #require(oracle.entries.first)
        let failure = try #require(entry.failureMinutes)
        let result = PassPredictor().passes(for: oracle.elements, observer: entry.observer, from: entry.from, through: entry.through)
        #expect(result.problem == .decayed)
        #expect(result.passes.count == entry.list.count)
        #expect(result.passes.count >= 1)
        let first = try #require(result.passes.first)
        #expect(first.los < oracle.elements.epoch.addingTimeInterval(failure * 60))
        #expect(abs(first.maxElevationDegrees - entry.list[0].maxEl) < 0.1)
    }

    @Test func deepSpaceElementsReportUnsupportedDeepSpace() throws {
        let geo = try oracleElements("ver-26900")
        let result = PassPredictor().passes(for: geo, observer: Observer(latitudeDegrees: 35, longitudeDegrees: -109),
                                            from: geo.epoch, through: geo.epoch.addingTimeInterval(86_400))
        #expect(result.passes.isEmpty)
        guard case .unsupportedDeepSpace? = result.problem else {
            Issue.record("expected unsupportedDeepSpace, got \(String(describing: result.problem))")
            return
        }
    }

    @Test func emptyOrReversedWindowReturnsNothing() throws {
        let iss = try oracleElements("iss-2025-09-30")
        let observer = Observer(latitudeDegrees: 35, longitudeDegrees: -109)
        let t = iss.epoch
        #expect(PassPredictor().passes(for: iss, observer: observer, from: t, through: t).passes.isEmpty)
        #expect(PassPredictor().passes(for: iss, observer: observer, from: t, through: t.addingTimeInterval(-3600)).passes.isEmpty)
        let invalid = Observer(latitudeDegrees: 99, longitudeDegrees: 0)
        #expect(PassPredictor().passes(for: iss, observer: invalid, from: t, through: t.addingTimeInterval(86_400)).passes.isEmpty)
    }

    @Test func sunlightAtTheTimeOfClosestApproachIsReported() throws {
        let oracle = try #require(try PassOracle.load().first { $0.name == "meteor-m2-4" })
        let entry = try #require(oracle.entries.first)
        let result = PassPredictor().passes(for: oracle.elements, observer: entry.observer, from: entry.from, through: entry.through)
        let expectedElevation = result.passes.map { SunPosition.elevationDegrees(from: entry.observer, at: $0.tca) }
        #expect(zip(result.passes, expectedElevation).allSatisfy { abs($0.sunElevationAtTCADegrees - $1) < 1e-9 })
        #expect(result.passes.contains { $0.sunlitAtTCA } && result.passes.contains { !$0.sunlitAtTCA },
                "a sun-synchronous satellite should be lit on some passes and in shadow on others over three days")
    }

    @Test func performance() throws {
        let base = try oracleElements("meteor-m2-4")
        var sets: [OrbitalElements] = []
        for index in 0..<100 {
            var copy = base
            copy.noradID = 90_000 + index
            copy.raanDegrees = (base.raanDegrees + Double(index) * 3.6).truncatingRemainder(dividingBy: 360)
            copy.meanAnomalyDegrees = (base.meanAnomalyDegrees + Double(index) * 7.3).truncatingRemainder(dividingBy: 360)
            sets.append(copy)
        }
        let observer = Observer(latitudeDegrees: 35.2534, longitudeDegrees: -109.4374, altitudeMeters: 1800)
        let predictor = PassPredictor()
        let started = Date()
        var total = 0
        for elements in sets {
            total += predictor.passes(for: elements, observer: observer, from: base.epoch, through: base.epoch.addingTimeInterval(7 * 86_400)).passes.count
        }
        let seconds = Date().timeIntervalSince(started)
        print("PERFORMANCE: 100 element sets x 7 days = \(total) passes in \(String(format: "%.2f", seconds)) s")
        #expect(total > 1000)
        #expect(seconds < 5, "took \(seconds) s")
    }
}

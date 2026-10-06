import Testing
import Foundation
@testable import SignalHiveCore

/// A pass with only the fields the rater reads set to something meaningful.
private func pass(maxElevation: Double, minutes: Double = 10) -> PredictedPass {
    let aos = Date(timeIntervalSince1970: 1_790_000_000)
    let los = aos.addingTimeInterval(minutes * 60)
    return PredictedPass(id: "1-1", noradID: 1, satelliteName: "TEST", aos: aos, tca: aos.addingTimeInterval(minutes * 30), los: los,
                         aosAzimuthDegrees: 0, tcaAzimuthDegrees: 90, losAzimuthDegrees: 180, maxElevationDegrees: maxElevation,
                         minRangeKM: 800, sunElevationAtTCADegrees: 10, sunlitAtTCA: true, startsBeforeWindow: false,
                         endsAfterWindow: false, elementEpoch: aos, track: [])
}

private func transmitter(mhz: Double, mode: String = "LRPT") -> TransmitterInfo {
    TransmitterInfo(id: "t", noradID: 1, summary: "test", downlinkHz: mhz * 1e6, mode: mode,
                    kind: SignalKind(satnogsMode: mode, baud: nil), isActive: true, service: nil, verifiedOnAir: nil)
}

private func antenna(_ name: String, mhz: ClosedRange<Double>, gain: AntennaProfile.Gain = .omni, directional: Bool = false) -> AntennaProfile {
    AntennaProfile(id: UUID(), name: name, lowHz: mhz.lowerBound * 1e6, highHz: mhz.upperBound * 1e6, gain: gain,
                   isDirectional: directional, notes: "")
}

private let mast = antenna("Telescopic mast", mhz: 100...800)

private func rate(_ pass: PredictedPass, transmitter: TransmitterInfo? = transmitter(mhz: 137.9), strength: SignalStrengthClass = .medium,
                  antennas: [AntennaProfile] = [mast], confidence: ElementConfidence = .good, tracking: Bool = false) -> PassRating {
    PassRater.rate(pass: pass, transmitter: transmitter, strength: strength, antennas: antennas, receiver: .rtlSDR,
                   confidence: confidence, trackingAvailable: tracking)
}

struct PassRatingTests {
    @Test func noTransmitterIsNotReceivableWithAReason() {
        let rating = rate(pass(maxElevation: 80), transmitter: nil)
        #expect(rating.grade == .notReceivable)
        #expect(rating.score == 0)
        #expect(rating.reasons.contains("No known active downlink"))
    }

    @Test func outOfDongleRangeNamesTheRange() {
        let rating = rate(pass(maxElevation: 80), transmitter: transmitter(mhz: 2247.5), antennas: [antenna("dish", mhz: 1000...3000)])
        #expect(rating.grade == .notReceivable)
        #expect(rating.reasons.first?.contains("24") == true && rating.reasons.first?.contains("1766") == true, "reasons: \(rating.reasons)")
    }

    @Test func noAntennaCoveringTheBandIsNotReceivableWithARemedy() {
        // 1.7 GHz is inside the dongle's range, but the mast kit's telescopic antenna stops at 800 MHz.
        let rating = rate(pass(maxElevation: 80), transmitter: transmitter(mhz: 1701.3, mode: "AHRPT"))
        #expect(rating.grade == .notReceivable)
        #expect(rating.reasons.contains("None of your antennas covers 1701.3 MHz"))
        #expect(rating.remedy == "Add or buy an antenna covering 1701.3 MHz")
        let none = rate(pass(maxElevation: 80), antennas: [])
        #expect(none.grade == .notReceivable)
        #expect(none.reasons.contains("None of your antennas covers 137.9 MHz"))
    }

    @Test func weakSatelliteWithMastKitNeedsAHighPass() {
        let low = rate(pass(maxElevation: 50), strength: .weak)
        #expect(low.grade == .poor)
        #expect(low.reasons.contains { $0.contains("55°") }, "reasons: \(low.reasons)")
        let high = rate(pass(maxElevation: 60), strength: .weak)
        #expect(high.grade > .poor)
        #expect(!high.reasons.contains { $0.contains("below the") })
    }

    @Test func strongSatelliteLowPassIsStillFine() {
        let rating = rate(pass(maxElevation: 12), strength: .strong)
        #expect(rating.grade >= .marginal, "grade \(rating.grade) score \(rating.score): \(rating.reasons)")
        #expect(!rating.reasons.contains { $0.contains("below the") })
        // Below the 10 degrees a strong signal needs with an omni antenna, it is capped at poor and says so.
        let tooLow = rate(pass(maxElevation: 8), strength: .strong)
        #expect(tooLow.grade == .poor && tooLow.reasons.contains { $0.contains("10°") })
    }

    @Test func minimumUsefulElevationTableIsExact() {
        let cases: [(SignalStrengthClass, AntennaProfile.Gain, Double)] = [
            (.strong, .omni, 10), (.strong, .low, 5), (.strong, .medium, 0), (.strong, .high, 0),
            (.medium, .omni, 35), (.medium, .low, 25), (.medium, .medium, 10), (.medium, .high, 0),
            (.weak, .omni, 55), (.weak, .low, 45), (.weak, .medium, 30), (.weak, .high, 10),
            (.unknown, .omni, 40), (.unknown, .low, 30), (.unknown, .medium, 15), (.unknown, .high, 5),
        ]
        for (strength, gain, minimum) in cases {
            #expect(PassRater.minimumUsefulElevation(strength: strength, gain: gain) == minimum, "\(strength) \(gain)")
        }
    }

    @Test func directionalAntennaWithoutTrackingGetsNoGainAndSaysSo() {
        let yagi = antenna("Handheld yagi", mhz: 130...150, gain: .high, directional: true)
        let without = rate(pass(maxElevation: 50), strength: .medium, antennas: [yagi], tracking: false)
        #expect(without.reasons.contains { $0.contains("hand pointing or a rotator") }, "reasons: \(without.reasons)")
        let asOmni = rate(pass(maxElevation: 50), strength: .medium, antennas: [antenna("Same band omni", mhz: 130...150)], tracking: false)
        #expect(without.score == asOmni.score, "a directional antenna counts as omni without tracking")
    }

    @Test func directionalAntennaWithTrackingScoresHigher() {
        let yagi = antenna("Handheld yagi", mhz: 130...150, gain: .high, directional: true)
        let with = rate(pass(maxElevation: 50), strength: .medium, antennas: [yagi], tracking: true)
        let without = rate(pass(maxElevation: 50), strength: .medium, antennas: [yagi], tracking: false)
        #expect(with.score == without.score + 14, "high (20) instead of omni (6)")
        #expect(with.grade >= without.grade)
    }

    @Test func theBestCoveringAntennaIsUsed() {
        let better = antenna("Turnstile", mhz: 130...150, gain: .medium)
        let both = rate(pass(maxElevation: 50), antennas: [mast, better])
        let onlyMast = rate(pass(maxElevation: 50), antennas: [mast])
        #expect(both.score == onlyMast.score + 10)
        #expect(both.reasons.contains { $0.contains("Turnstile") })
    }

    @Test func elementConfidenceAdjustments() {
        let base = rate(pass(maxElevation: 60), strength: .strong)
        let aging = rate(pass(maxElevation: 60), strength: .strong, confidence: .aging(days: 4))
        #expect(aging.score == base.score - 5)
        let stale = rate(pass(maxElevation: 60), strength: .strong, confidence: .stale(days: 10))
        #expect(stale.score == base.score - 15)
        #expect(stale.grade <= .marginal, "stale elements cap the grade at marginal, got \(stale.grade)")
        for confidence in [ElementConfidence.unusable(days: 40), .fromTheFuture] {
            let rating = rate(pass(maxElevation: 60), strength: .strong, confidence: confidence)
            #expect(rating.grade == .notReceivable, "\(confidence)")
            #expect(!rating.reasons.isEmpty)
        }
    }

    @Test func gradeThresholdsAreBoundaryExact() {
        let table: [(Int, PassGrade)] = [(0, .poor), (39, .poor), (40, .marginal), (54, .marginal), (55, .good), (69, .good), (70, .excellent), (100, .excellent)]
        for (score, grade) in table {
            #expect(PassRater.grade(forScore: score) == grade, "score \(score)")
        }
    }

    @Test func scoreIsTheSumOfItsStatedParts() {
        // 60 degrees peak (40) + 10 minutes (10 * 600/600 = 10) + strong (30) + omni (6) = 86.
        let rating = rate(pass(maxElevation: 60, minutes: 10), strength: .strong)
        #expect(rating.score == 86)
        #expect(rating.grade == .excellent)
        // 30 degrees (20) + 5 minutes (5) + weak (8) + omni (6) = 39.
        #expect(rate(pass(maxElevation: 30, minutes: 5), strength: .weak).score == 39)
        // Elevation above 60 and duration above 10 minutes add nothing more.
        #expect(rate(pass(maxElevation: 90, minutes: 20), strength: .strong).score == 86)
    }

    @Test func gradesAreOrdered() {
        #expect(PassGrade.notReceivable < .poor && PassGrade.poor < .marginal && PassGrade.marginal < .good && PassGrade.good < .excellent)
    }
}

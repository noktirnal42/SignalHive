import Foundation

public struct RatedPass: Identifiable, Sendable {
    public var pass: PredictedPass
    public var record: SatelliteRecord
    public var transmitter: TransmitterInfo?
    public var rating: PassRating
    public var confidence: ElementConfidence

    public var id: String { pass.id }
}

/// A satellite that could not be predicted, and why, so the screen can say so instead of silently dropping it.
public struct SatelliteProblem: Sendable, Equatable {
    public var noradID: Int
    public var name: String
    public var message: String
}

public struct PassBoardResult: Sendable {
    public var passes: [RatedPass]
    public var problems: [SatelliteProblem]
    /// Satellites on periods of 225 minutes and more (geostationary weather satellites, Molniya orbits). They do not
    /// have passes in this phase's sense and need the deep-space model, so they are counted, not reported as faults.
    public var deepSpaceSkipped: Int
}

public enum PassBoard {
    /// Predicts and rates the passes of every satellite for one observer. One bad satellite (stale or future elements,
    /// a decay partway through the window) becomes a `SatelliteProblem` and never affects the others; passes a decaying
    /// satellite finished before it failed are still listed.
    public static func compute(records: [SatelliteRecord], observer: Observer, antennas: [AntennaProfile], from: Date,
                               horizon: TimeInterval, minimumElevationDegrees: Double, now: Date) -> PassBoardResult {
        var passes: [RatedPass] = []
        var problems: [SatelliteProblem] = []
        var skipped = 0
        let predictor = PassPredictor(minimumElevationDegrees: minimumElevationDegrees)
        for record in records {
            let elements = record.elements
            if elements.isDeepSpace {
                skipped += 1
                continue
            }
            let confidence = ElementAge.confidence(epoch: elements.epoch, now: now)
            switch confidence {
            case let .unusable(days):
                problems.append(SatelliteProblem(noradID: elements.noradID, name: elements.name,
                                                 message: "Elements are \(Int(days.rounded())) days old (over 30), too old to predict from"))
                continue
            case .fromTheFuture:
                problems.append(SatelliteProblem(noradID: elements.noradID, name: elements.name,
                                                 message: "The element set is dated in the future: the feed or this Mac's clock is wrong"))
                continue
            case .good, .aging, .stale:
                break
            }
            let result = predictor.passes(for: elements, observer: observer, from: from, through: from.addingTimeInterval(horizon))
            if let problem = result.problem {
                problems.append(SatelliteProblem(noradID: elements.noradID, name: elements.name,
                                                 message: message(for: problem, keptPasses: !result.passes.isEmpty)))
            }
            let transmitter = record.primaryTransmitter
            for pass in result.passes {
                let rating = PassRater.rate(pass: pass, transmitter: transmitter, strength: record.strength, antennas: antennas,
                                            receiver: .rtlSDR, confidence: confidence)
                passes.append(RatedPass(pass: pass, record: record, transmitter: transmitter, rating: rating, confidence: confidence))
            }
        }
        passes.sort { ($0.pass.aos, $0.pass.noradID) < ($1.pass.aos, $1.pass.noradID) }
        return PassBoardResult(passes: passes, problems: problems, deepSpaceSkipped: skipped)
    }

    private static func message(for error: SGP4Error, keptPasses: Bool) -> String {
        let tail = keptPasses ? "; the passes before that are shown" : ""
        switch error {
        case .decayed: return "The orbit model says it has decayed (re-entered)\(tail)"
        case .meanElementsOutOfRange, .perturbedElementsOutOfRange: return "The orbit elements go out of range inside the window\(tail)"
        case .semiLatusRectumNegative: return "The orbit model fails inside the window\(tail)"
        case .nonFiniteInput: return "The element set holds a value that is not a number"
        case .unsupportedDeepSpace: return "Needs the deep-space orbit model, which is not built yet"
        }
    }
}

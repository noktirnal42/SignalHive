import Foundation

/// What the receiver can tune. Both ends are inclusive.
public struct ReceiverCapability: Sendable {
    public var tuningRangeHz: ClosedRange<Double>

    public init(tuningRangeHz: ClosedRange<Double>) {
        self.tuningRangeHz = tuningRangeHz
    }

    public static let rtlSDR = ReceiverCapability(tuningRangeHz: 24e6...1_766e6)
}

public enum PassGrade: Int, Comparable, Sendable {
    case notReceivable, poor, marginal, good, excellent

    public static func < (lhs: PassGrade, rhs: PassGrade) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PassRating: Sendable, Equatable {
    public var grade: PassGrade
    public var score: Int
    /// Every fact that moved the score or capped the grade, in plain words.
    public var reasons: [String]
    /// What would make this pass receivable or better, when there is something to do.
    public var remedy: String?
}

/// Rates a pass for the owner's own antennas and dongle. The rules are initial heuristics, stated on screen as such, to
/// be replaced by evidence from received passes. It is a pure function: the same inputs always give the same rating,
/// and every part of the score appears in `reasons`.
public enum PassRater {
    public static func rate(pass: PredictedPass, transmitter: TransmitterInfo?, strength: SignalStrengthClass,
                            antennas: [AntennaProfile], receiver: ReceiverCapability, confidence: ElementConfidence,
                            trackingAvailable: Bool = false) -> PassRating {
        func notReceivable(_ reason: String, remedy: String? = nil) -> PassRating {
            PassRating(grade: .notReceivable, score: 0, reasons: [reason], remedy: remedy)
        }
        guard let transmitter else { return notReceivable("No known active downlink") }
        let mhz = megahertz(transmitter.downlinkHz)
        guard receiver.tuningRangeHz.contains(transmitter.downlinkHz) else {
            return notReceivable("Downlink \(mhz) MHz is outside what the RTL-SDR tunes (\(megahertz(receiver.tuningRangeHz.lowerBound)) to \(megahertz(receiver.tuningRangeHz.upperBound)) MHz)")
        }
        let covering = antennas.filter { $0.covers(transmitter.downlinkHz) }
        guard !covering.isEmpty else {
            return notReceivable("None of your antennas covers \(mhz) MHz", remedy: "Add or buy an antenna covering \(mhz) MHz")
        }
        switch confidence {
        case let .unusable(days):
            return notReceivable("Elements are \(Int(days)) days old: the predicted times cannot be trusted", remedy: "Update the elements")
        case .fromTheFuture:
            return notReceivable("The element set is dated in the future: the feed or this Mac's clock is wrong")
        case .good, .aging, .stale:
            break
        }

        var reasons: [String] = []
        var total = 0.0

        let elevationPoints = min(pass.maxElevationDegrees, 60) / 60 * 40
        total += elevationPoints
        reasons.append("Peak elevation \(Int(pass.maxElevationDegrees.rounded()))°: +\(Int(elevationPoints.rounded()))")

        let durationPoints = min(pass.duration, 600) / 600 * 10
        total += durationPoints
        reasons.append("Pass length \(Int((pass.duration / 60).rounded())) min: +\(Int(durationPoints.rounded()))")

        let strengthPoints: Double
        switch strength {
        case .strong: strengthPoints = 30
        case .medium: strengthPoints = 20
        case .weak: strengthPoints = 8
        case .unknown: strengthPoints = 12
        }
        total += strengthPoints
        reasons.append("Signal strength \(strength.rawValue): +\(Int(strengthPoints))")

        // A directional antenna earns its gain only when something points it.
        func effectiveGain(_ antenna: AntennaProfile) -> AntennaProfile.Gain {
            antenna.isDirectional && !trackingAvailable ? .omni : antenna.gain
        }
        let best = covering.max { antennaPoints(effectiveGain($0)) < antennaPoints(effectiveGain($1)) } ?? covering[0]
        let gain = effectiveGain(best)
        total += antennaPoints(gain)
        reasons.append("Antenna \(best.name) (\(gain.rawValue)): +\(Int(antennaPoints(gain)))")
        if let directional = covering.first(where: { $0.isDirectional }), !trackingAvailable {
            reasons.append("\(directional.name) is directional: it needs hand pointing or a rotator, so it is counted as an omni antenna here")
        }

        var cap: PassGrade?
        switch confidence {
        case let .aging(days):
            total -= 5
            reasons.append("Elements \(Int(days)) days old: -5")
        case let .stale(days):
            total -= 15
            cap = .marginal
            reasons.append("Elements \(Int(days)) days old: -15, and the grade is capped at marginal")
        default:
            break
        }

        let score = max(0, min(100, Int(total.rounded())))
        var grade = grade(forScore: score)
        var remedy: String?
        if let cap, grade > cap { grade = cap }

        let needed = minimumUsefulElevation(strength: strength, gain: gain)
        if pass.maxElevationDegrees < needed {
            reasons.append("Peak elevation \(Int(pass.maxElevationDegrees.rounded()))° is below the \(Int(needed))° a \(strength.rawValue) signal needs with a \(gain.rawValue) antenna: capped at poor")
            remedy = "A higher pass (\(Int(needed))° or more), or a higher-gain antenna, would help"
            if grade > .poor { grade = .poor }
        }
        return PassRating(grade: grade, score: score, reasons: reasons, remedy: remedy)
    }

    /// 70 and up excellent, 55 good, 40 marginal, below that poor.
    static func grade(forScore score: Int) -> PassGrade {
        switch score {
        case 70...: return .excellent
        case 55...: return .good
        case 40...: return .marginal
        default: return .poor
        }
    }

    /// The lowest peak elevation worth trying: below it the signal is too far down in the noise and the ground clutter.
    static func minimumUsefulElevation(strength: SignalStrengthClass, gain: AntennaProfile.Gain) -> Double {
        switch (strength, gain) {
        case (.strong, .omni): return 10
        case (.strong, .low): return 5
        case (.strong, _): return 0
        case (.medium, .omni): return 35
        case (.medium, .low): return 25
        case (.medium, .medium): return 10
        case (.medium, .high): return 0
        case (.weak, .omni): return 55
        case (.weak, .low): return 45
        case (.weak, .medium): return 30
        case (.weak, .high): return 10
        case (.unknown, .omni): return 40
        case (.unknown, .low): return 30
        case (.unknown, .medium): return 15
        case (.unknown, .high): return 5
        }
    }

    private static func antennaPoints(_ gain: AntennaProfile.Gain) -> Double {
        switch gain {
        case .omni: return 6
        case .low: return 10
        case .medium: return 16
        case .high: return 20
        }
    }

    /// "137.9", "1701.3", "137.9125": as many decimals as the number needs, up to four.
    static func megahertz(_ hz: Double) -> String {
        var text = String(format: "%.4f", hz / 1e6)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

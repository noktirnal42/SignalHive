import Foundation

/// How far an element set can be trusted for pass prediction, by its age. SGP4 drifts along-track by a few kilometres a
/// day for a low orbit, so a week-old set can be minutes out and a month-old one is not worth showing.
public enum ElementConfidence: Sendable, Equatable {
    case good
    case aging(days: Double)
    case stale(days: Double)
    case unusable(days: Double)
    /// The epoch is more than an hour ahead of the clock: a bad feed or a wrong system clock.
    case fromTheFuture
}

public enum ElementAge {
    public static func confidence(epoch: Date, now: Date) -> ElementConfidence {
        let days = now.timeIntervalSince(epoch) / 86_400
        if days < -1.0 / 24 { return .fromTheFuture }
        switch days {
        case ..<3: return .good
        case ..<7: return .aging(days: days)
        case ..<30: return .stale(days: days)
        default: return .unusable(days: days)
        }
    }
}

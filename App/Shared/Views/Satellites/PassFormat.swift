import SwiftUI
import SignalHiveCore

/// Display helpers for the Passes screen. Layout is always in UTC; only the labels change zone.
enum PassFormat {
    static func time(_ date: Date, utc: Bool) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: utc ? .gmt : .current))
    }

    static func day(_ date: Date, utc: Bool) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc ? .gmt : .current))
    }

    static func hourLabel(_ date: Date, utc: Bool) -> String {
        date.formatted(Date.FormatStyle(timeZone: utc ? .gmt : .current).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    static func countdown(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 { return "\(total / 3600) h \((total % 3600) / 60) min" }
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    static func megahertz(_ hz: Double) -> String {
        var text = String(format: "%.4f", hz / 1e6)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + " MHz"
    }

    static func gradeName(_ grade: PassGrade) -> String {
        switch grade {
        case .notReceivable: return "Not receivable"
        case .poor: return "Poor"
        case .marginal: return "Marginal"
        case .good: return "Good"
        case .excellent: return "Excellent"
        }
    }

    static func gradeColor(_ grade: PassGrade) -> Color {
        switch grade {
        case .notReceivable: return .gray
        case .poor: return HiveInk.copper
        case .marginal: return HiveInk.amber
        case .good: return HiveInk.cyan
        case .excellent: return HiveInk.mint
        }
    }

    static func decoderText(_ status: DecoderStatus) -> String {
        switch status {
        case .ready: return "decoder: ready"
        case .planned: return "decoder: planned"
        case .none: return "no decoder"
        }
    }
}

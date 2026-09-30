import Foundation

/// Turning what a person types (or clicks) into a frequency.
public enum FrequencyEntry {

    /// Parses "155.475", "155,475", "155.475 MHz", "162550 kHz", "155475000", "0.9 GHz" into megahertz.
    /// A bare number is read as MHz when it is in the RTL-SDR's tuning range (24-1766, so "1090" is ADS-B),
    /// as Hz from 1,000,000 up, and otherwise as kHz ("121500" is the airband emergency channel).
    public static func parseMHz(_ text: String) -> Double? {
        var cleaned = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        var unit = 0.0                                           // 0 = unspecified
        for (suffix, factor) in [("ghz", 1000.0), ("mhz", 1.0), ("khz", 0.001), ("hz", 0.000_001)] where cleaned.hasSuffix(suffix) {
            cleaned.removeLast(suffix.count)
            unit = factor
            break
        }
        guard let value = Double(cleaned), value.isFinite, value > 0 else { return nil }
        if unit > 0 { return value * unit }
        if (24...1766).contains(value) || value < 24 && value.truncatingRemainder(dividingBy: 1) != 0 { return value }
        if value >= 1_000_000 { return value / 1_000_000 }
        if value >= 1000 { return value / 1000 }
        return value
    }

    /// Rounds to the nearest multiple of `stepKHz` (so a click on the spectrum lands on a channel).
    public static func snap(mhz: Double, stepKHz: Double) -> Double {
        guard stepKHz > 0 else { return mhz }
        let snapped = (mhz * 1000 / stepKHz).rounded() * stepKHz / 1000
        return (snapped * 1_000_000).rounded() / 1_000_000       // remove floating-point dust
    }
}

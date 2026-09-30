import Foundation

/// The dB range a spectrum or waterfall is drawn against. Chosen from the data, relative to the measured
/// noise floor, so signals stay visible whatever the gain or dongle (a fixed range washes real hardware out).
public struct SpectrumScale: Equatable, Sendable {
    public var minDB: Float
    public var maxDB: Float

    public init(minDB: Float, maxDB: Float) {
        self.minDB = minDB
        self.maxDB = maxDB
    }

    /// Floor a little below the median (the noise), ceiling at least 30 dB above it and never below the peak.
    public static func auto(for spectrum: [Float]) -> SpectrumScale {
        guard !spectrum.isEmpty else { return SpectrumScale(minDB: -120, maxDB: 0) }
        let median = spectrum.sorted()[spectrum.count / 2]
        let peak = spectrum.max() ?? median
        let low = median - 8
        let high = max(median + 30, peak + 3)
        return SpectrumScale(minDB: low, maxDB: max(high, low + 20))
    }

    /// 0...1 position of a level within the range.
    public func normalized(_ value: Float) -> Float {
        guard maxDB > minDB else { return 0 }
        return min(1, max(0, (value - minDB) / (maxDB - minDB)))
    }
}

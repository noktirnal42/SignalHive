import Foundation
import SignalHiveCore

// MARK: - Frequency Finder: discover active frequencies from a live spectrum sweep

public struct FoundFrequency: Identifiable, Sendable, Hashable {
    public var frequencyHz: Double
    public var strengthDB: Float
    public var id: String { "\(Int(frequencyHz))" }

    public var displayMHz: String {
        String(format: "%.4f MHz", frequencyHz / 1_000_000)
    }
}

public enum FrequencyFinder {

    /// Detect spectral peaks above a threshold, converted to absolute frequencies.
    /// - Parameters:
    ///   - magnitudes: FFT magnitudes in dBFS (from DSPPipeline.subscribeToFFT)
    ///   - centerFrequencyHz: tuner center frequency
    ///   - sampleRateHz: tuner sample rate
    ///   - thresholdDB: minimum peak level
    public static func find(
        magnitudes: [Float],
        centerFrequencyHz: Double,
        sampleRateHz: Double,
        thresholdDB: Float = -55
    ) -> [FoundFrequency] {
        guard magnitudes.count > 8 else { return [] }
        let n = magnitudes.count
        let binHz = sampleRateHz / Double(n)
        var found: [FoundFrequency] = []

        // Local-maximum detection with a small neighborhood.
        for i in 2..<(n - 2) {
            let v = magnitudes[i]
            guard v > thresholdDB else { continue }
            guard v >= magnitudes[i - 1], v >= magnitudes[i + 1],
                  v > magnitudes[i - 2], v > magnitudes[i + 2]
            else { continue }

            let freq = centerFrequencyHz + (Double(i) - Double(n) / 2) * binHz
            // Skip DC spike
            guard abs(freq - centerFrequencyHz) > 200_000 else { continue }
            // Skip out-of-band edges
            guard freq > 0 else { continue }

            found.append(FoundFrequency(frequencyHz: freq, strengthDB: v))
        }

        // Cluster peaks within 12.5 kHz, keep the strongest per cluster.
        found.sort { $0.frequencyHz < $1.frequencyHz }
        var clustered: [FoundFrequency] = []
        for peak in found {
            if let last = clustered.last, abs(peak.frequencyHz - last.frequencyHz) < 12_500 {
                if peak.strengthDB > last.strengthDB {
                    clustered[clustered.count - 1] = peak
                }
            } else {
                clustered.append(peak)
            }
        }
        return clustered
    }
}

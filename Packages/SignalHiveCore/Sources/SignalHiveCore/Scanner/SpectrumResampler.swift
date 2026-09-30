import Foundation

/// Reduces a spectrum to a drawable number of bins without losing narrow signals.
public enum SpectrumResampler {

    /// Splits `bins` into `count` contiguous groups and keeps the maximum of each (so a single strong carrier
    /// is still visible after a 16x reduction, which averaging would bury).
    public static func maxPool(_ bins: [Float], to count: Int) -> [Float] {
        guard count > 0, !bins.isEmpty else { return [] }
        guard bins.count > count else { return bins }
        return (0..<count).map { index in
            let start = index * bins.count / count
            let end = max(start + 1, (index + 1) * bins.count / count)
            return bins[start..<min(end, bins.count)].max() ?? bins[start]
        }
    }
}

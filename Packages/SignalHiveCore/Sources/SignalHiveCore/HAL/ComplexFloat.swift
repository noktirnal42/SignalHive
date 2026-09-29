import Foundation
import Accelerate

/// A single complex sample: real (I) + imaginary (Q) components.
public struct ComplexFloat: Sendable, Equatable {
    public var i: Float
    public var q: Float

    public init(i: Float = 0, q: Float = 0) {
        self.i = i
        self.q = q
    }

    public var magnitude: Float { sqrtf(i * i + q * q) }
    public var powerLinear: Float { i * i + q * q }
    public var powerDBFS: Float { 10.0 * log10f(max(powerLinear, 1e-12)) }
    public var phase: Float { atan2f(q, i) }

    public static func + (lhs: ComplexFloat, rhs: ComplexFloat) -> ComplexFloat {
        ComplexFloat(i: lhs.i + rhs.i, q: lhs.q + rhs.q)
    }

    public static func * (lhs: ComplexFloat, rhs: Float) -> ComplexFloat {
        ComplexFloat(i: lhs.i * rhs, q: lhs.q * rhs)
    }

    /// Multiply by complex exponential: multiply two complex numbers.
    public static func * (lhs: ComplexFloat, rhs: ComplexFloat) -> ComplexFloat {
        ComplexFloat(
            i: lhs.i * rhs.i - lhs.q * rhs.q,
            q: lhs.i * rhs.q + lhs.q * rhs.i
        )
    }
}

// MARK: - Batch utility helpers

public extension Array where Element == ComplexFloat {
    /// Convert to interleaved Float array [I0, Q0, I1, Q1, ...]
    var interleaved: [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        for (idx, sample) in enumerated() {
            out[idx * 2]     = sample.i
            out[idx * 2 + 1] = sample.q
        }
        return out
    }

    /// Power spectrum in dBFS for each sample (useful for simple squelch checks).
    var powerDBFS: [Float] {
        map(\.powerDBFS)
    }

    /// RMS power in dBFS across the buffer.
    var rmsDBFS: Float {
        guard !isEmpty else { return -160 }
        var sum: Float = 0
        for s in self { sum += s.powerLinear }
        return 10.0 * log10f(sum / Float(count))
    }
}

// MARK: - Conversion from raw hardware formats

public extension Array where Element == ComplexFloat {
    /// From RTL-SDR uint8 interleaved: 128 = DC offset, range 0–255.
    init(rtlRaw: UnsafeBufferPointer<UInt8>) {
        self = stride(from: 0, to: rtlRaw.count - 1, by: 2).map { idx in
            ComplexFloat(
                i: (Float(rtlRaw[idx]) - 127.5) / 127.5,
                q: (Float(rtlRaw[idx + 1]) - 127.5) / 127.5
            )
        }
    }

    /// From HackRF int8 interleaved: range -128 to 127.
    init(hackRFRaw: UnsafeBufferPointer<Int8>) {
        self = stride(from: 0, to: hackRFRaw.count - 1, by: 2).map { idx in
            ComplexFloat(
                i: Float(hackRFRaw[idx]) / 128.0,
                q: Float(hackRFRaw[idx + 1]) / 128.0
            )
        }
    }

    /// From int16 interleaved (LimeSDR, PlutoSDR, SDRPlay).
    init(int16Raw: UnsafeBufferPointer<Int16>) {
        self = stride(from: 0, to: int16Raw.count - 1, by: 2).map { idx in
            ComplexFloat(
                i: Float(int16Raw[idx]) / 32768.0,
                q: Float(int16Raw[idx + 1]) / 32768.0
            )
        }
    }

    /// From float32 interleaved (OpenWebRX, test signal).
    init(float32Raw: UnsafeBufferPointer<Float>) {
        self = stride(from: 0, to: float32Raw.count - 1, by: 2).map { idx in
            ComplexFloat(i: float32Raw[idx], q: float32Raw[idx + 1])
        }
    }
}

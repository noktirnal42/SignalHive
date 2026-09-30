import Foundation
import Accelerate

// MARK: - FIR design

public enum FIRDesign {
    /// Linear-phase low-pass FIR (Blackman-windowed sinc) with unity gain at DC.
    /// Flat up to `passbandHz`, about -6 dB half-way to `stopbandHz`, and below -70 dB from `stopbandHz` on.
    /// Tap count follows the transition width (about 5.5 * sampleRate / transition), always odd, capped at 4001.
    public static func lowPass(passbandHz: Double, stopbandHz: Double, sampleRate: Double) -> [Float] {
        let transition = max(1, stopbandHz - passbandHz)
        var count = Int((5.5 * sampleRate / transition).rounded(.up))
        count = min(4001, max(15, count))
        if count % 2 == 0 { count += 1 }

        let cutoff = (passbandHz + stopbandHz) / 2 / sampleRate                 // cycles per sample
        let middle = Double(count - 1) / 2
        var taps = [Double](repeating: 0, count: count)
        for n in 0..<count {
            let x = Double(n) - middle
            let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
            let phase = 2 * Double.pi * Double(n) / Double(count - 1)
            let window = 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)         // Blackman
            taps[n] = sinc * window
        }
        let sum = taps.reduce(0, +)
        return taps.map { Float($0 / sum) }
    }
}

// MARK: - Streaming decimating FIR

/// A FIR filter that keeps every `factor`-th output, streaming: the result does not depend on how the input
/// is cut into blocks. Uses vDSP's decimating correlation (identical to convolution for these symmetric taps).
struct DecimatingFIR {
    let taps: [Float]
    let factor: Int
    private var pendingI: [Float]
    private var pendingQ: [Float]

    init(taps: [Float], factor: Int) {
        self.taps = taps
        self.factor = max(1, factor)
        pendingI = [Float](repeating: 0, count: taps.count - 1)               // start from silence
        pendingQ = pendingI
    }

    mutating func process(i: [Float], q: [Float]) -> (i: [Float], q: [Float]) {
        pendingI += i
        pendingQ += q
        let available = pendingI.count
        guard available >= taps.count else { return ([], []) }
        let outputCount = (available - taps.count) / factor + 1

        var outI = [Float](repeating: 0, count: outputCount)
        var outQ = [Float](repeating: 0, count: outputCount)
        pendingI.withUnsafeBufferPointer { input in
            vDSP_desamp(input.baseAddress!, vDSP_Stride(factor), taps, &outI, vDSP_Length(outputCount), vDSP_Length(taps.count))
        }
        pendingQ.withUnsafeBufferPointer { input in
            vDSP_desamp(input.baseAddress!, vDSP_Stride(factor), taps, &outQ, vDSP_Length(outputCount), vDSP_Length(taps.count))
        }
        let consumed = outputCount * factor
        pendingI.removeFirst(consumed)
        pendingQ.removeFirst(consumed)
        return (outI, outQ)
    }

    /// Real-valued input (audio): same filter and decimation, one channel.
    mutating func processReal(_ x: [Float]) -> [Float] {
        pendingI += x
        let available = pendingI.count
        guard available >= taps.count else { return [] }
        let outputCount = (available - taps.count) / factor + 1
        var out = [Float](repeating: 0, count: outputCount)
        pendingI.withUnsafeBufferPointer { input in
            vDSP_desamp(input.baseAddress!, vDSP_Stride(factor), taps, &out, vDSP_Length(outputCount), vDSP_Length(taps.count))
        }
        pendingI.removeFirst(outputCount * factor)
        return out
    }
}

// MARK: - Channel down-converter

/// Extracts one channel from a wideband IQ capture: shifts it to 0 Hz, filters everything else away, and
/// decimates to an audio-friendly rate. This is what lets a scanner listen to a channel that is not at the
/// tuner centre, and to one channel among many neighbours.
///
/// Two stages keep it cheap: a gentle filter drops the rate a long way first, then a sharp filter (about 4 kHz
/// transition for a 12.5 kHz channel) selects the channel at the lower rate.
public final class ChannelDownconverter: @unchecked Sendable {
    public let sampleRate: Double
    public let offsetHz: Double
    public let bandwidthHz: Double
    /// Total decimation, so `outputRate == sampleRate / decimation`.
    public let decimation: Int
    public var outputRate: Double { sampleRate / Double(decimation) }

    private var phase = 0.0                                   // oscillator phase, radians, wrapped to +-pi
    private let phaseStep: Double
    private var coarse: DecimatingFIR
    private var fine: DecimatingFIR

    /// - Parameters:
    ///   - offsetHz: channel frequency minus tuner centre (negative = below).
    ///   - bandwidthHz: the channel's width (12,500 for narrowband FM).
    ///   - targetOutputRate: desired audio-side rate; the real rate is `sampleRate / decimation`.
    public init(sampleRate: Double, offsetHz: Double, bandwidthHz: Double, targetOutputRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.offsetHz = offsetHz
        self.bandwidthHz = bandwidthHz
        self.phaseStep = -2 * Double.pi * offsetHz / sampleRate

        // Choose a decimation near sampleRate / target that splits into two usable stages.
        let ideal = max(1, Int(sampleRate / max(1, targetOutputRate)))
        var chosen = (total: ideal, first: 1)
        for candidate in stride(from: ideal, through: max(1, ideal - 6), by: -1) {
            if let divisor = (2...24).reversed().first(where: { candidate % $0 == 0 }) {
                chosen = (candidate, divisor)
                break
            }
        }
        decimation = chosen.total
        let firstFactor = chosen.first
        let secondFactor = chosen.total / chosen.first

        // Channel selectivity (second stage, at the intermediate rate): flat to 45% of the channel width,
        // deep from 75%.
        let selectivityPass = bandwidthHz * 0.45
        let selectivityStop = bandwidthHz * 0.75
        let intermediateRate = sampleRate / Double(firstFactor)

        // First stage: keep everything the second stage will keep, and reject whatever would alias into it.
        coarse = DecimatingFIR(
            taps: FIRDesign.lowPass(passbandHz: selectivityStop,
                                    stopbandHz: max(selectivityStop * 1.5, intermediateRate - selectivityStop),
                                    sampleRate: sampleRate),
            factor: firstFactor)
        fine = DecimatingFIR(
            taps: FIRDesign.lowPass(passbandHz: selectivityPass, stopbandHz: selectivityStop, sampleRate: intermediateRate),
            factor: secondFactor)
    }

    /// Feed consecutive blocks of the wideband capture; returns the channel's baseband IQ at `outputRate`.
    public func process(_ iq: [ComplexFloat]) -> [ComplexFloat] {
        guard !iq.isEmpty else { return [] }
        let count = iq.count

        // Mix by exp(-j*2*pi*offset*n/fs). The angle is computed per sample in Double, then wrapped per block.
        var angles = [Double](repeating: 0, count: count)
        for n in 0..<count { angles[n] = phase + Double(n) * phaseStep }
        var sines = [Double](repeating: 0, count: count)
        var cosines = [Double](repeating: 0, count: count)
        var length = Int32(count)
        vvsincos(&sines, &cosines, angles, &length)

        var mixedI = [Float](repeating: 0, count: count)
        var mixedQ = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let c = Float(cosines[n]), s = Float(sines[n])
            mixedI[n] = iq[n].i * c - iq[n].q * s
            mixedQ[n] = iq[n].i * s + iq[n].q * c
        }
        phase = (phase + Double(count) * phaseStep).truncatingRemainder(dividingBy: 2 * Double.pi)

        let stage1 = coarse.process(i: mixedI, q: mixedQ)
        let stage2 = fine.process(i: stage1.i, q: stage1.q)
        return zip(stage2.i, stage2.q).map { ComplexFloat(i: $0, q: $1) }
    }

    /// Restart from silence (call when retuning).
    public func reset() {
        phase = 0
        coarse = DecimatingFIR(taps: coarse.taps, factor: coarse.factor)
        fine = DecimatingFIR(taps: fine.taps, factor: fine.factor)
    }
}

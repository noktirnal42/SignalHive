import Testing
import Foundation
@testable import SignalHiveCore

/// Power (dB, relative to 1.0) of a complex response at `frequency` (Hz), for a real FIR at `sampleRate`.
private func responseDB(_ taps: [Float], at frequency: Double, sampleRate: Double) -> Double {
    var re = 0.0, im = 0.0
    for (n, tap) in taps.enumerated() {
        let angle = -2 * Double.pi * frequency * Double(n) / sampleRate
        re += Double(tap) * cos(angle)
        im += Double(tap) * sin(angle)
    }
    return 20 * log10(max(1e-12, (re * re + im * im).squareRoot()))
}

struct FIRDesignTests {
    @Test func aLowPassPassesDCAtUnityGainAndIsSymmetric() {
        let taps = FIRDesign.lowPass(cutoffHz: 8_000, transitionHz: 6_000, sampleRate: 146_000)
        #expect(abs(taps.reduce(0, +) - 1) < 1e-4)
        #expect(taps.count % 2 == 1)
        for i in 0..<taps.count / 2 { #expect(abs(taps[i] - taps[taps.count - 1 - i]) < 1e-7) }
    }

    @Test func thePassbandIsFlatAndTheStopbandIsDeep() {
        let rate = 146_000.0
        let taps = FIRDesign.lowPass(cutoffHz: 8_000, transitionHz: 6_000, sampleRate: rate)
        #expect(abs(responseDB(taps, at: 4_000, sampleRate: rate)) < 0.2)                 // passband
        #expect(responseDB(taps, at: 8_000, sampleRate: rate) > -4 && responseDB(taps, at: 8_000, sampleRate: rate) < -2)   // ~ -3 dB at the cutoff
        #expect(responseDB(taps, at: 14_000, sampleRate: rate) < -50)                    // beyond the transition
        #expect(responseDB(taps, at: 40_000, sampleRate: rate) < -60)
    }
}

struct ChannelDownconverterTests {
    static let rate = 2_048_000.0

    static func tone(_ offsetHz: Double, count: Int, start: Int = 0, amplitude: Float = 1) -> [ComplexFloat] {
        (start..<start + count).map { n in
            let phase = 2 * Double.pi * offsetHz * Double(n) / rate
            return ComplexFloat(i: Float(cos(phase)) * amplitude, q: Float(sin(phase)) * amplitude)
        }
    }

    static func power(_ samples: ArraySlice<ComplexFloat>) -> Double {
        samples.reduce(0) { $0 + Double($1.i * $1.i + $1.q * $1.q) } / Double(max(1, samples.count))
    }

    @Test func theOutputRateIsTheInputRateOverTheDecimation() {
        let ddc = ChannelDownconverter(sampleRate: Self.rate, offsetHz: 0, bandwidthHz: 12_500, targetOutputRate: 48_000)
        #expect(ddc.decimation >= 30 && ddc.decimation <= 45)
        #expect(abs(ddc.outputRate - Self.rate / Double(ddc.decimation)) < 1e-6)
        #expect(ddc.outputRate > 40_000 && ddc.outputRate < 60_000)          // usable for audio
        let output = ddc.process(Self.tone(0, count: 200_000))
        #expect(abs(output.count - 200_000 / ddc.decimation) <= 4)
    }

    @Test func aToneAtTheChannelOffsetComesOutAsSteadyBaseband() {
        let ddc = ChannelDownconverter(sampleRate: Self.rate, offsetHz: 300_000, bandwidthHz: 12_500, targetOutputRate: 48_000)
        let output = ddc.process(Self.tone(300_000, count: 400_000))
        let settled = output.dropFirst(200)                                   // skip filter warm-up
        let magnitudes = settled.map { Double(($0.i * $0.i + $0.q * $0.q).squareRoot()) }
        #expect(abs(magnitudes.reduce(0, +) / Double(magnitudes.count) - 1) < 0.02)   // unity gain
        #expect((magnitudes.max()! - magnitudes.min()!) < 0.02)                        // steady
        // and it sits at DC: the phase barely moves from sample to sample
        let drift = zip(settled, settled.dropFirst()).map { abs(atan2(Double($1.q), Double($1.i)) - atan2(Double($0.q), Double($0.i))) }
        #expect(drift.max()! < 0.05)
    }

    @Test(arguments: [50_000.0, 100_000.0, 700_000.0, -400_000.0])
    func signalsOutsideTheChannelAreRejectedHard(interfererOffsetHz: Double) {
        let ddc = ChannelDownconverter(sampleRate: Self.rate, offsetHz: 300_000, bandwidthHz: 12_500, targetOutputRate: 48_000)
        let wanted = Self.power(ddc.process(Self.tone(300_000, count: 300_000))[200...])
        let other = ChannelDownconverter(sampleRate: Self.rate, offsetHz: 300_000, bandwidthHz: 12_500, targetOutputRate: 48_000)
        let leaked = Self.power(other.process(Self.tone(300_000 + interfererOffsetHz, count: 300_000))[200...])
        #expect(10 * log10(leaked / wanted) < -60)
    }

    @Test func aneighbouringChannelIsRejectedToo() {
        // A 12.5 kHz channel spacing: the next channel up carries a signal 20 dB stronger than ours.
        let make = { ChannelDownconverter(sampleRate: Self.rate, offsetHz: 300_000, bandwidthHz: 12_500, targetOutputRate: 48_000) }
        let wanted = Self.power(make().process(Self.tone(300_000, count: 300_000))[200...])
        let leaked = Self.power(make().process(Self.tone(312_500, count: 300_000, amplitude: 10))[200...])
        #expect(10 * log10(leaked / wanted) < 0 - 0)          // even 20 dB stronger, it is quieter than the wanted signal
    }

    @Test func blockBoundariesDoNotChangeTheResult() {
        let signal = Self.tone(250_000, count: 60_000)
        let whole = ChannelDownconverter(sampleRate: Self.rate, offsetHz: 250_000, bandwidthHz: 12_500, targetOutputRate: 48_000).process(signal)
        let chunked = ChannelDownconverter(sampleRate: Self.rate, offsetHz: 250_000, bandwidthHz: 12_500, targetOutputRate: 48_000)
        var pieces: [ComplexFloat] = []
        var index = 0
        for size in [1, 7, 4096, 333, 16_384, 9, 20_000, 1000, 5000] where index < signal.count {
            let end = min(signal.count, index + size)
            pieces += chunked.process(Array(signal[index..<end]))
            index = end
        }
        pieces += chunked.process(Array(signal[index...]))
        #expect(abs(pieces.count - whole.count) <= 1)
        let common = min(pieces.count, whole.count)
        let worst = (0..<common).map { abs(pieces[$0].i - whole[$0].i) + abs(pieces[$0].q - whole[$0].q) }.max() ?? 1
        #expect(worst < 1e-3)
    }

    @Test func aNarrowbandFMSignalIsRecoveredNextToAStrongInterferer() {
        // 800 Hz tone, 3 kHz deviation, at +250 kHz; a signal 20 dB stronger 37.5 kHz away.
        let count = 400_000
        var fmPhase = 0.0
        let wanted = (0..<count).map { n -> ComplexFloat in
            fmPhase += 2 * Double.pi * 3_000 * sin(2 * Double.pi * 800 * Double(n) / Self.rate) / Self.rate
            let carrier = 2 * Double.pi * 250_000 * Double(n) / Self.rate
            return ComplexFloat(i: Float(cos(carrier + fmPhase)), q: Float(sin(carrier + fmPhase)))
        }
        let interferer = Self.tone(287_500, count: count, amplitude: 10)
        let mixed = zip(wanted, interferer).map { ComplexFloat(i: $0.i + $1.i, q: $0.q + $1.q) }

        let ddc = ChannelDownconverter(sampleRate: Self.rate, offsetHz: 250_000, bandwidthHz: 12_500, targetOutputRate: 48_000)
        let baseband = ddc.process(mixed)
        let audio = NFMDemodulator(sampleRate: ddc.outputRate, bandwidth: 12_500, deviationHz: 3_000).demodulate(iq: baseband)

        // The strongest audio component must be the 800 Hz tone.
        let settled = Array(audio.dropFirst(500).prefix(4096))
        let processor = FFTProcessor(fftSize: 4096)
        let spectrum = processor.process(samples: settled.map { ComplexFloat(i: $0, q: 0) }).averaged
        let binHz = ddc.outputRate / 4096
        let peak = spectrum.indices.max { spectrum[$0] < spectrum[$1] }!
        let peakHz = abs(Double(peak - 2048) * binHz)
        #expect(abs(peakHz - 800) < 2 * binHz)
    }
}

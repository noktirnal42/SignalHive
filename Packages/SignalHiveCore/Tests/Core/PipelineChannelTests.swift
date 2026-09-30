import Testing
import Foundation
@testable import SignalHiveCore

/// Collects audio from a pipeline (thread-safe: the pipeline delivers on its own actor).
private final class AudioCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate = 0.0
    func add(_ new: [Float], rate newRate: Double) { lock.lock(); samples += new; rate = newRate; lock.unlock() }
    var snapshot: (samples: [Float], rate: Double) { lock.lock(); defer { lock.unlock() }; return (samples, rate) }
}

struct PipelineChannelTests {
    static let sampleRate = 2_048_000.0

    /// NFM signal (3 kHz deviation) with `toneHz` audio at `offsetHz` from the centre.
    static func fm(offsetHz: Double, toneHz: Double, count: Int, amplitude: Float = 0.5) -> [ComplexFloat] {
        var phase = 0.0
        return (0..<count).map { n in
            phase += 2 * Double.pi * 3_000 * sin(2 * Double.pi * toneHz * Double(n) / sampleRate) / sampleRate
            let carrier = 2 * Double.pi * offsetHz * Double(n) / sampleRate + phase
            return ComplexFloat(i: Float(cos(carrier)) * amplitude, q: Float(sin(carrier)) * amplitude)
        }
    }

    static func mix(_ a: [ComplexFloat], _ b: [ComplexFloat]) -> [ComplexFloat] {
        zip(a, b).map { ComplexFloat(i: $0.i + $1.i, q: $0.q + $1.q) }
    }

    static func dominantHz(_ audio: [Float], rate: Double) -> Double {
        let window = Array(audio.dropFirst(1500).prefix(4096))
        guard window.count == 4096 else { return -1 }
        let spectrum = FFTProcessor(fftSize: 4096).process(samples: window.map { ComplexFloat(i: $0, q: 0) }).averaged
        let peak = spectrum.indices.max { spectrum[$0] < spectrum[$1] } ?? 0
        return abs(Double(peak - 2048)) * rate / 4096
    }

    /// Runs `signal` through a pipeline listening to `offsetHz`; returns audio, whether squelch was open at the end.
    static func listen(to offsetHz: Double, signal: [ComplexFloat], squelch: Float = -60) async throws -> (audio: [Float], rate: Double, open: Bool) {
        let pipeline = DSPPipeline(device: TestSignalDevice())
        var config = DSPPipeline.Config()
        config.mode = .nfm
        config.audioOutputEnabled = false
        config.classificationEnabled = false
        config.channelOffsetHz = offsetHz
        config.squelchDBFS = squelch
        try await pipeline.configure(config)
        let collector = AudioCollector()
        await pipeline.subscribeToAudio { samples, rate in collector.add(samples, rate: rate) }
        var index = 0
        while index < signal.count {
            let end = min(signal.count, index + 16_384)
            await pipeline.ingest(samples: Array(signal[index..<end]))
            index = end
        }
        let heard = collector.snapshot
        return (heard.samples, heard.rate, await pipeline.isSquelchOpen)
    }

    @Test func theChannelOffsetChoosesWhichSimultaneousSignalIsHeard() async throws {
        let count = 16_384 * 24
        let capture = Self.mix(Self.fm(offsetHz: 250_000, toneHz: 800, count: count),
                               Self.fm(offsetHz: -300_000, toneHz: 1_500, count: count))
        let upper = try await Self.listen(to: 250_000, signal: capture)
        let lower = try await Self.listen(to: -300_000, signal: capture)
        #expect(upper.rate > 40_000 && upper.rate < 60_000)                 // real audio rate, not 2 MHz
        #expect(abs(Self.dominantHz(upper.audio, rate: upper.rate) - 800) < 30)
        #expect(abs(Self.dominantHz(lower.audio, rate: lower.rate) - 1_500) < 30)
    }

    @Test func squelchFollowsTheChannelNotTheWholeBand() async throws {
        // Only a strong signal at -300 kHz. Listening there is open; listening at +250 kHz (empty) is closed
        // even though the wideband power is high.
        let count = 16_384 * 8
        let capture = Self.fm(offsetHz: -300_000, toneHz: 800, count: count, amplitude: 0.5)
        let onSignal = try await Self.listen(to: -300_000, signal: capture)
        let offSignal = try await Self.listen(to: 250_000, signal: capture)
        #expect(onSignal.open)
        #expect(!offSignal.open)
        let silentPower = offSignal.audio.map { $0 * $0 }.reduce(0, +) / Float(max(1, offSignal.audio.count))
        #expect(silentPower < 1e-6)                                          // squelch really muted the audio
    }
}

import Foundation
import Accelerate

/// Built-in software test signal generator — no hardware required.
/// Generates synthetic IQ frames with configurable modulation for demo/testing.
public final class TestSignalDevice: SDRDevice, @unchecked Sendable {
    public let id = UUID()
    public let name = "Test Signal Generator"
    public let serial = "TEST-0001"
    public let deviceType: SDRDeviceType = .testSignal

    public let frequencyRange: ClosedRange<Double> = 100_000...6_000_000_000
    public let supportedSampleRates: [Double] = [250_000, 1_024_000, 2_048_000, 4_000_000, 8_000_000]
    public let gainRange: ClosedRange<Double> = 0...50
    public let supportsTX = false

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 2_048_000
    public private(set) var currentGain: Double = 30

    public enum SignalMode: String, CaseIterable, Sendable {
        case fm          = "FM Stereo"
        case am          = "AM Broadcast"
        case nfm         = "NFM Voice"
        case noiseOnly   = "Noise Floor"
        case multitone   = "Multi-tone"
        case bpsk        = "BPSK"
    }

    public var signalMode: SignalMode = .fm
    public var signalPower: Float = -40    // dBFS
    public var noisePower: Float = -90     // dBFS

    private var isStreaming = false
    private var streamTask: Task<Void, Never>?

    public init() {}

    public func open() async throws {}

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        currentFrequency = frequency
        currentSampleRate = sampleRate
        currentGain = gain
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        isStreaming = true
        let sampleRate = currentSampleRate
        let mode = signalMode
        let sigPow = signalPower
        let noisePow = noisePower

        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let blockSize = 16384
            var phase: Float = 0
            var fmPhase: Float = 0
            var audioPhase: Float = 0

            while await self.isStreamingFlag() {
                var samples = [ComplexFloat](repeating: .init(), count: blockSize)
                let dt = 1.0 / Float(sampleRate)
                let sigAmplitude = powf(10, sigPow / 20)
                let noiseAmplitude = powf(10, noisePow / 20)

                for i in 0..<blockSize {
                    let t = Float(i) * dt
                    let noise = ComplexFloat(
                        i: Float.random(in: -1...1) * noiseAmplitude,
                        q: Float.random(in: -1...1) * noiseAmplitude
                    )

                    let signal: ComplexFloat
                    switch mode {
                    case .fm:
                        // FM: 1 kHz audio tone, 75 kHz deviation
                        audioPhase += 2 * .pi * 1000 * dt
                        fmPhase += 2 * .pi * 75000 * sinf(audioPhase) * dt
                        signal = ComplexFloat(i: cosf(fmPhase), q: sinf(fmPhase)) * sigAmplitude

                    case .am:
                        // AM: carrier + 1 kHz modulation at 80%
                        audioPhase += 2 * .pi * 1000 * dt
                        let modulated = (1 + 0.8 * sinf(audioPhase)) * sigAmplitude
                        signal = ComplexFloat(i: cosf(phase) * modulated, q: sinf(phase) * modulated)
                        phase += 2 * .pi * 100 * dt  // 100 Hz IF offset

                    case .nfm:
                        // NFM: narrowband FM, 3 kHz deviation, 800 Hz tone
                        audioPhase += 2 * .pi * 800 * dt
                        fmPhase += 2 * .pi * 3000 * sinf(audioPhase) * dt
                        signal = ComplexFloat(i: cosf(fmPhase), q: sinf(fmPhase)) * sigAmplitude

                    case .noiseOnly:
                        signal = .init()

                    case .multitone:
                        // 3 tones at -200, 0, +300 kHz offset
                        let t1 = ComplexFloat(i: cosf(phase - 200000 * 2 * .pi * t),
                                              q: sinf(phase - 200000 * 2 * .pi * t))
                        let t2 = ComplexFloat(i: cosf(phase), q: sinf(phase))
                        let t3 = ComplexFloat(i: cosf(phase + 300000 * 2 * .pi * t),
                                              q: sinf(phase + 300000 * 2 * .pi * t))
                        signal = (t1 + t2 + t3) * (sigAmplitude / 3)

                    case .bpsk:
                        // BPSK: 1200 baud, alternating bits
                        let bitPeriod = Float(sampleRate) / 1200
                        let bit = Int(Float(i) / bitPeriod) % 2
                        let bpskPhase = phase + Float(bit) * .pi
                        signal = ComplexFloat(i: cosf(bpskPhase), q: sinf(bpskPhase)) * sigAmplitude
                        phase += 2 * .pi * 1200 * dt
                    }

                    samples[i] = signal + noise
                }

                // Convert to uint8 interleaved for uniform callback signature
                var raw = [UInt8](repeating: 0, count: blockSize * 2)
                for (idx, s) in samples.enumerated() {
                    raw[idx * 2]     = UInt8(max(0, min(255, Int((s.i * 127.5) + 127.5))))
                    raw[idx * 2 + 1] = UInt8(max(0, min(255, Int((s.q * 127.5) + 127.5))))
                }
                raw.withUnsafeBufferPointer { buf in
                    callback(buf, blockSize)
                }

                // Pace at roughly real-time
                let blockDuration = UInt64(Double(blockSize) / sampleRate * 1_000_000_000)
                try? await Task.sleep(nanoseconds: blockDuration)
            }
        }
    }

    public func stopStreaming() async {
        isStreaming = false
        streamTask?.cancel()
        streamTask = nil
    }

    public func close() async {
        await stopStreaming()
    }

    private func isStreamingFlag() async -> Bool { isStreaming }
}

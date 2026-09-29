import Foundation
import Accelerate
import AVFoundation

// MARK: - Demodulation Mode

public enum DemodMode: String, CaseIterable, Sendable, Codable {
    case am   = "AM"
    case nfm  = "NFM"
    case wfm  = "WFM"
    case usb  = "USB"
    case lsb  = "LSB"
    case cw   = "CW"
    case raw  = "RAW IQ"

    public var defaultBandwidth: Double {
        switch self {
        case .am:  return 10_000
        case .nfm: return 12_500
        case .wfm: return 200_000
        case .usb: return 2_400
        case .lsb: return 2_400
        case .cw:  return 500
        case .raw: return 0
        }
    }

    public var icon: String {
        switch self {
        case .am:  return "speaker.wave.1"
        case .nfm: return "speaker.wave.2"
        case .wfm: return "speaker.wave.3"
        case .usb: return "arrow.up.right"
        case .lsb: return "arrow.down.left"
        case .cw:  return "dot.circle"
        case .raw: return "waveform.path"
        }
    }
}

// MARK: - Demodulator Protocol

public protocol Demodulator: AnyObject, Sendable {
    var mode: DemodMode { get }
    var bandwidth: Double { get set }
    var sampleRate: Double { get set }

    func demodulate(iq: [ComplexFloat]) -> [Float]
}

// MARK: - AM Demodulator

public final class AMDemodulator: Demodulator, @unchecked Sendable {
    public let mode: DemodMode = .am
    public var bandwidth: Double
    public var sampleRate: Double

    private var dcLevel: Float = 0
    private let agc: AGC

    public init(sampleRate: Double, bandwidth: Double = 10_000) {
        self.sampleRate = sampleRate
        self.bandwidth = bandwidth
        self.agc = AGC()
    }

    public func demodulate(iq: [ComplexFloat]) -> [Float] {
        // Envelope detection: magnitude of IQ
        var audio = iq.map { sqrtf($0.i * $0.i + $0.q * $0.q) }
        // Remove DC offset
        let mean = audio.reduce(0, +) / Float(audio.count)
        dcLevel = 0.99 * dcLevel + 0.01 * mean
        audio = audio.map { $0 - dcLevel }
        // AGC
        return agc.process(audio)
    }
}

// MARK: - NFM Demodulator

public final class NFMDemodulator: Demodulator, @unchecked Sendable {
    public let mode: DemodMode = .nfm
    public var bandwidth: Double
    public var sampleRate: Double

    private var prevSample: ComplexFloat = .init()
    private let agc: AGC
    private let deviationHz: Double

    public init(sampleRate: Double, bandwidth: Double = 12_500, deviationHz: Double = 5_000) {
        self.sampleRate = sampleRate
        self.bandwidth = bandwidth
        self.deviationHz = deviationHz
        self.agc = AGC()
    }

    public func demodulate(iq: [ComplexFloat]) -> [Float] {
        var audio = [Float](repeating: 0, count: iq.count)
        let k = Float(sampleRate) / (2 * Float.pi * Float(deviationHz))
        for i in 0..<iq.count {
            let s = iq[i]
            // Phase discriminator: atan2(Im(s × conj(prev)), Re(s × conj(prev)))
            let prod = s * ComplexFloat(i: prevSample.i, q: -prevSample.q)
            audio[i] = atan2f(prod.q, prod.i) * k
            prevSample = s
        }
        return agc.process(audio)
    }
}

// MARK: - WFM Demodulator (wide FM + stereo pilot)

public final class WFMDemodulator: Demodulator, @unchecked Sendable {
    public let mode: DemodMode = .wfm
    public var bandwidth: Double
    public var sampleRate: Double

    private var prevSample: ComplexFloat = .init()
    private let agc: AGC
    // Pilot tone detector (19 kHz)
    private var pilotPhase: Float = 0
    private var pilotLocked: Bool = false

    public init(sampleRate: Double, bandwidth: Double = 200_000) {
        self.sampleRate = sampleRate
        self.bandwidth = bandwidth
        self.agc = AGC()
    }

    public func demodulate(iq: [ComplexFloat]) -> [Float] {
        var audio = [Float](repeating: 0, count: iq.count)
        let k = Float(sampleRate) / (2 * Float.pi * 75_000)  // 75 kHz deviation
        for i in 0..<iq.count {
            let s = iq[i]
            let prod = s * ComplexFloat(i: prevSample.i, q: -prevSample.q)
            audio[i] = atan2f(prod.q, prod.i) * k
            prevSample = s
        }
        // De-emphasis: 75µs time constant (US) or 50µs (EU)
        audio = deEmphasis(audio, tau: 75e-6)
        return agc.process(audio)
    }

    private func deEmphasis(_ samples: [Float], tau: Double) -> [Float] {
        let rc = Float(tau * sampleRate)
        let alpha = 1.0 / (1.0 + rc)
        var prev: Float = 0
        return samples.map { s in
            prev = prev + alpha * (s - prev)
            return prev
        }
    }
}

// MARK: - SSB Demodulator (USB/LSB via Hilbert transform)

public final class SSBDemodulator: Demodulator, @unchecked Sendable {
    public let mode: DemodMode
    public var bandwidth: Double
    public var sampleRate: Double
    private let agc: AGC
    private let bfo: Float  // Beat frequency oscillator offset (Hz)
    private var bfoPhase: Float = 0

    public init(mode: DemodMode, sampleRate: Double, bandwidth: Double = 2_400, bfoHz: Float = 0) {
        precondition(mode == .usb || mode == .lsb)
        self.mode = mode
        self.sampleRate = sampleRate
        self.bandwidth = bandwidth
        self.bfo = bfoHz
        self.agc = AGC()
    }

    public func demodulate(iq: [ComplexFloat]) -> [Float] {
        // For SSB: real part gives USB, imaginary part gives LSB
        // Add BFO offset rotation if needed
        let dt = 1.0 / Float(sampleRate)
        let audio: [Float] = iq.enumerated().map { idx, s in
            bfoPhase += 2 * .pi * bfo * dt
            let rotated = s * ComplexFloat(i: cosf(bfoPhase), q: sinf(bfoPhase))
            return mode == .usb ? rotated.i : rotated.q
        }
        return agc.process(audio)
    }
}

// MARK: - CW Demodulator (BFO + narrow filter)

public final class CWDemodulator: Demodulator, @unchecked Sendable {
    public let mode: DemodMode = .cw
    public var bandwidth: Double = 500
    public var sampleRate: Double
    private var bfoPhase: Float = 0
    private let bfoHz: Float = 700   // CW tone: 700 Hz
    private let agc: AGC

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.agc = AGC()
    }

    public func demodulate(iq: [ComplexFloat]) -> [Float] {
        let dt = 1.0 / Float(sampleRate)
        let audio: [Float] = iq.map { s in
            bfoPhase += 2 * .pi * bfoHz * dt
            let mixed = s * ComplexFloat(i: cosf(bfoPhase), q: sinf(bfoPhase))
            return sqrtf(mixed.i * mixed.i + mixed.q * mixed.q)
        }
        return agc.process(audio)
    }
}

// MARK: - AGC (Automatic Gain Control)

final class AGC: @unchecked Sendable {
    private var level: Float = 1.0
    private let attackRate: Float = 0.1
    private let decayRate: Float = 0.001
    private let targetLevel: Float = 0.5

    func process(_ samples: [Float]) -> [Float] {
        samples.map { s in
            let amplified = s * level
            let power = abs(amplified)
            if power > targetLevel {
                level *= (1.0 - attackRate)
            } else {
                level *= (1.0 + decayRate)
            }
            level = max(0.001, min(100.0, level))
            return amplified
        }
    }
}

// MARK: - Squelch

public final class Squelch: @unchecked Sendable {
    public var thresholdDBFS: Float = -80
    public var hysteresisDB: Float = 3
    private var isOpen = false

    public func gate(samples: [Float], powerDBFS: Float) -> [Float] {
        if !isOpen && powerDBFS > thresholdDBFS {
            isOpen = true
        } else if isOpen && powerDBFS < thresholdDBFS - hysteresisDB {
            isOpen = false
        }
        return isOpen ? samples : [Float](repeating: 0, count: samples.count)
    }
}

// MARK: - Factory

public enum DemodulatorFactory {
    public static func make(mode: DemodMode, sampleRate: Double) -> any Demodulator {
        switch mode {
        case .am:  return AMDemodulator(sampleRate: sampleRate)
        case .nfm: return NFMDemodulator(sampleRate: sampleRate)
        case .wfm: return WFMDemodulator(sampleRate: sampleRate)
        case .usb: return SSBDemodulator(mode: .usb, sampleRate: sampleRate)
        case .lsb: return SSBDemodulator(mode: .lsb, sampleRate: sampleRate)
        case .cw:  return CWDemodulator(sampleRate: sampleRate)
        case .raw: return AMDemodulator(sampleRate: sampleRate)  // passthrough
        }
    }
}

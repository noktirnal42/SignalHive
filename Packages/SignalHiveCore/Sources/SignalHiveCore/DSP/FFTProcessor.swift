import Foundation
import Accelerate

/// Real-time FFT processor using vDSP (Accelerate framework).
/// Computes power spectrum in dBFS, with windowing, averaging, and peak hold.
public final class FFTProcessor: @unchecked Sendable {
    // MARK: - Configuration

    public struct Config: Sendable {
        public var fftSize: Int = 4096
        public var window: WindowType = .hann
        public var averagingAlpha: Float = 0.3    // EMA weight for new frame
        public var peakHoldDecayDB: Float = 0.5   // dB/frame decay for peak hold
        public var referenceLevel: Float = 0       // dBFS reference (0 = full scale)

        public init() {}
    }

    public enum WindowType: String, CaseIterable, Sendable {
        case rectangular    = "Rectangular"
        case hann           = "Hann"
        case hamming        = "Hamming"
        case blackmanHarris = "Blackman-Harris"
        case flattop        = "Flat Top"
    }

    // MARK: - State

    private let config: Config
    private let log2n: Int
    // Use the C-level complex-to-complex FFT (vDSP_fft_zip) rather than the Swift
    // vDSP.FFT<DSPSplitComplex> wrapper, which is a real (not complex) FFT.
    private let fftSetup: OpaquePointer  // FFTSetup
    private let windowCoeffs: [Float]

    // Output buffers (allocated once, reused each frame)
    private var splitReal: [Float]
    private var splitImag: [Float]
    private var powerSpectrum: [Float]           // Linear power
    private var averagedSpectrum: [Float]         // EMA-averaged dBFS
    private var peakHoldSpectrum: [Float]         // Peak hold dBFS

    private var isFirstFrame = true

    public var fftSize: Int { config.fftSize }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    public convenience init(fftSize: Int, windowType: WindowType = .hann) {
        var config = Config()
        config.fftSize = fftSize
        config.window = windowType
        self.init(config: config)
    }

    public init(config: Config = Config()) {
        self.config = config
        let size = config.fftSize
        self.log2n = Int(log2(Double(size)))

        self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
        self.windowCoeffs = Self.makeWindow(type: config.window, size: size)

        self.splitReal = [Float](repeating: 0, count: size)
        self.splitImag = [Float](repeating: 0, count: size)
        self.powerSpectrum   = [Float](repeating: 0, count: size / 2)
        self.averagedSpectrum = [Float](repeating: -120, count: size / 2)
        self.peakHoldSpectrum = [Float](repeating: -120, count: size / 2)
    }

    // MARK: - Main processing

    /// Process one block of IQ samples.
    /// - Returns: (averaged dBFS spectrum, peak-hold dBFS spectrum), each length fftSize/2
    public func process(samples: [ComplexFloat]) -> (averaged: [Float], peakHold: [Float]) {
        let n = min(samples.count, config.fftSize)

        // Apply window and split into real/imag
        for i in 0..<n {
            splitReal[i] = samples[i].i * windowCoeffs[i]
            splitImag[i] = samples[i].q * windowCoeffs[i]
        }
        // Zero-pad remainder
        if n < config.fftSize {
            for i in n..<config.fftSize {
                splitReal[i] = 0
                splitImag[i] = 0
            }
        }

        // Complex-to-complex FFT (vDSP_fft_zip is in-place, log2n-length transform)
        splitReal.withUnsafeMutableBufferPointer { rPtr in
            splitImag.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(
                    realp: rPtr.baseAddress!,
                    imagp: iPtr.baseAddress!
                )
                vDSP_fft_zip(fftSetup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            }
        }

        // Compute power spectrum: |FFT[k]|² / (N²)
        let normFactor = 1.0 / Float(config.fftSize * config.fftSize)
        for k in 0..<config.fftSize / 2 {
            powerSpectrum[k] = (splitReal[k] * splitReal[k] + splitImag[k] * splitImag[k]) * normFactor
        }

        // Convert to dBFS
        var dbfs = [Float](repeating: 0, count: config.fftSize / 2)
        for k in 0..<config.fftSize / 2 {
            dbfs[k] = 10 * log10f(max(powerSpectrum[k], 1e-12)) + config.referenceLevel
        }

        // EMA averaging
        let alpha = config.averagingAlpha
        if isFirstFrame {
            averagedSpectrum = dbfs
            peakHoldSpectrum = dbfs
            isFirstFrame = false
        } else {
            for k in 0..<config.fftSize / 2 {
                averagedSpectrum[k] = alpha * dbfs[k] + (1 - alpha) * averagedSpectrum[k]
                // Peak hold with decay
                if dbfs[k] > peakHoldSpectrum[k] {
                    peakHoldSpectrum[k] = dbfs[k]
                } else {
                    peakHoldSpectrum[k] = max(dbfs[k], peakHoldSpectrum[k] - config.peakHoldDecayDB)
                }
            }
        }

        return (averagedSpectrum, peakHoldSpectrum)
    }

    /// Reset averaging and peak hold (call on frequency change).
    public func reset() {
        isFirstFrame = true
        averagedSpectrum = [Float](repeating: -120, count: config.fftSize / 2)
        peakHoldSpectrum = [Float](repeating: -120, count: config.fftSize / 2)
    }

    /// Convert FFT bin index to frequency offset from center (Hz).
    public func binToFrequency(bin: Int, sampleRate: Double, centerFrequency: Double) -> Double {
        let binWidth = sampleRate / Double(config.fftSize)
        // Bins 0..N/2-1 map to 0..sampleRate/2 (positive), N/2..N-1 to -sampleRate/2..0 (negative)
        // After FFT shift: bin 0 = center, bins increase to the right
        let offset: Double
        if bin < config.fftSize / 2 {
            offset = Double(bin) * binWidth
        } else {
            offset = Double(bin - config.fftSize) * binWidth
        }
        return centerFrequency + offset
    }

    // MARK: - Window generation

    private static func makeWindow(type: WindowType, size: Int) -> [Float] {
        var w = [Float](repeating: 1, count: size)
        switch type {
        case .rectangular:
            return w
        case .hann:
            vDSP_hann_window(&w, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        case .hamming:
            vDSP_hamm_window(&w, vDSP_Length(size), 0)
        case .blackmanHarris:
            // Blackman-Harris: a0-a1*cos(2πn/N)+a2*cos(4πn/N)-a3*cos(6πn/N)
            let a0: Float = 0.35875, a1: Float = 0.48829, a2: Float = 0.14128, a3: Float = 0.01168
            for n in 0..<size {
                let x = 2 * Float.pi * Float(n) / Float(size)
                w[n] = a0 - a1 * cosf(x) + a2 * cosf(2 * x) - a3 * cosf(3 * x)
            }
        case .flattop:
            let a: [Float] = [0.21557895, 0.41663158, 0.277263158, 0.083578947, 0.006947368]
            for n in 0..<size {
                let x = 2 * Float.pi * Float(n) / Float(size)
                w[n] = a[0] - a[1]*cosf(x) + a[2]*cosf(2*x) - a[3]*cosf(3*x) + a[4]*cosf(4*x)
            }
        }
        return w
    }
}

// MARK: - Power measurement helpers

public extension FFTProcessor {
    /// Signal power in dBFS within a frequency band.
    func bandPower(spectrum: [Float], lowFreq: Double, highFreq: Double,
                   sampleRate: Double, centerFrequency: Double) -> Float {
        let binWidth = sampleRate / Double(config.fftSize)
        let lowBin = max(0, Int((lowFreq - centerFrequency + sampleRate / 2) / binWidth))
        let highBin = min(config.fftSize / 2 - 1, Int((highFreq - centerFrequency + sampleRate / 2) / binWidth))
        guard lowBin <= highBin else { return -120 }

        let slice = spectrum[lowBin...highBin]
        let maxPower = slice.max() ?? -120
        return maxPower
    }
}

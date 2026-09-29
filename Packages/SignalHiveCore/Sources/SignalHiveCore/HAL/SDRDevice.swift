import Foundation

// MARK: - SDR Device Protocol

/// Unified hardware abstraction for all supported SDR devices.
public protocol SDRDevice: AnyObject, Sendable {
    var id: UUID { get }
    var name: String { get }
    var serial: String { get }
    var deviceType: SDRDeviceType { get }

    var frequencyRange: ClosedRange<Double> { get }
    var supportedSampleRates: [Double] { get }
    var gainRange: ClosedRange<Double> { get }
    var supportsTX: Bool { get }

    var currentFrequency: Double { get }
    var currentSampleRate: Double { get }
    var currentGain: Double { get }

    func open() async throws
    func configure(frequency: Double, sampleRate: Double, gain: Double) async throws
    func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws
    func stopStreaming() async
    func close() async

    // Optional TX
    func transmit(samples: [ComplexFloat]) async throws
}

// MARK: - Default implementations for optional capabilities

public extension SDRDevice {
    var supportsTX: Bool { false }
    func transmit(samples: [ComplexFloat]) async throws {
        throw SDRError.notSupported("TX not supported by \(name)")
    }
}

// MARK: - Device Types

public enum SDRDeviceType: String, Sendable, CaseIterable {
    case rtlsdr    = "RTL-SDR"
    case hackrf    = "HackRF"
    case limesdr   = "LimeSDR"
    case sdrplay   = "SDRPlay"
    case airspy    = "Airspy"
    case plutosdr  = "PlutoSDR"
    case network   = "Network (rtl_tcp)"
    case openwebrx = "OpenWebRX"
    case testSignal = "Test Signal"

    public var icon: String {
        switch self {
        case .rtlsdr:     return "antenna.radiowaves.left.and.right"
        case .hackrf:     return "waveform"
        case .limesdr:    return "dot.radiowaves.forward"
        case .sdrplay:    return "dot.radiowaves.left.and.right"
        case .airspy:     return "dot.radiowaves.up.forward"
        case .plutosdr:   return "radio"
        case .network:    return "network"
        case .openwebrx:  return "globe"
        case .testSignal: return "waveform.path"
        }
    }
}

// MARK: - Raw sample format per device type

public enum SampleFormat: Sendable {
    case uint8Interleaved   // RTL-SDR: 0–255, 128 = DC
    case int8Interleaved    // HackRF: -128 to 127
    case int16Interleaved   // LimeSDR, PlutoSDR, SDRPlay: -32768 to 32767
    case float32Interleaved // OpenWebRX, TestSignal
}

// MARK: - Configuration

public struct SDRConfiguration: Sendable {
    public var frequency: Double      // Hz
    public var sampleRate: Double     // Samples/sec
    public var gain: Double           // dB (or 0–50 for RTL-SDR steps)
    public var ppmCorrection: Double  // Frequency offset correction in ppm
    public var dcOffset: Bool         // Enable DC offset correction

    public init(
        frequency: Double = 100_000_000,
        sampleRate: Double = 2_048_000,
        gain: Double = 30,
        ppmCorrection: Double = 0,
        dcOffset: Bool = true
    ) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.gain = gain
        self.ppmCorrection = ppmCorrection
        self.dcOffset = dcOffset
    }
}

// MARK: - Errors

public enum SDRError: Error, LocalizedError {
    case deviceNotFound(String)
    case openFailed(String)
    case configurationFailed(String)
    case streamingFailed(String)
    case notSupported(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let msg):      return "Device not found: \(msg)"
        case .openFailed(let msg):          return "Failed to open device: \(msg)"
        case .configurationFailed(let msg): return "Configuration failed: \(msg)"
        case .streamingFailed(let msg):     return "Streaming error: \(msg)"
        case .notSupported(let msg):        return "Not supported: \(msg)"
        case .networkError(let msg):        return "Network error: \(msg)"
        }
    }
}

// MARK: - Stream format descriptor (attached to each buffer)

public struct IQStreamInfo: Sendable {
    public let sampleFormat: SampleFormat
    public let sampleRate: Double
    public let centerFrequency: Double
    public let timestamp: Date

    public init(
        sampleFormat: SampleFormat,
        sampleRate: Double,
        centerFrequency: Double,
        timestamp: Date = .now
    ) {
        self.sampleFormat = sampleFormat
        self.sampleRate = sampleRate
        self.centerFrequency = centerFrequency
        self.timestamp = timestamp
    }
}

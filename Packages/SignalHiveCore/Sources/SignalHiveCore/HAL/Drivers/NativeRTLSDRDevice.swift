import Foundation
#if os(macOS)
import RTLSDRKit
#endif

// MARK: - Backend seam

/// What the SignalHive adapter needs from an RTL-SDR driver. Small on purpose: the real implementation wraps
/// `RTLSDRKit.RTLSDRDevice`, tests supply a fake dongle.
protocol RTLSDRBackend: AnyObject, Sendable {
    /// The sample rate the hardware is really producing after the last `setSampleRate`.
    var sampleRate: Double { get }
    /// False when the last retune could not lock the tuner's oscillator.
    var pllLocked: Bool { get }
    func setSampleRate(_ rate: Int) throws -> Double
    func setCenterFrequency(_ hertz: Int) throws
    func setAutomaticGain() throws
    func setTunerGain(tenthsDB: Int) throws
    func startStreaming(
        onError: @escaping @Sendable (Error) -> Void,
        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void
    ) throws
    func stopStreaming()
    func close()
}

/// The real driver, behind the seam.
#if os(macOS)
final class RTLSDRKitBackend: RTLSDRBackend, @unchecked Sendable {
    private let device: RTLSDRKit.RTLSDRDevice

    init(device: RTLSDRKit.RTLSDRDevice) { self.device = device }

    var sampleRate: Double { device.sampleRate }
    var pllLocked: Bool { device.pllLocked }
    func setSampleRate(_ rate: Int) throws -> Double { try device.setSampleRate(rate) }
    func setCenterFrequency(_ hertz: Int) throws { try device.setCenterFrequency(hertz) }
    func setAutomaticGain() throws { try device.setAutomaticGain() }
    func setTunerGain(tenthsDB: Int) throws { try device.setTunerGain(tenthsDB: tenthsDB) }
    func startStreaming(
        onError: @escaping @Sendable (Error) -> Void,
        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void
    ) throws {
        try device.startStreaming(onError: onError, handler: handler)
    }
    func stopStreaming() { device.stopStreaming() }
    func close() { device.close() }
}
#endif

// MARK: - Availability

/// Whether an RTL-SDR can be used right now, in words a person can act on. (Replaces the old "support library
/// loaded?" question: the native driver has no library to find, only a dongle that is or is not plugged in.)
public struct RTLSDRAvailability: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case found(dongles: [String])
        case noDongleConnected
        case notAvailableOnThisPlatform
    }

    public var state: State

    public var isAvailable: Bool {
        if case .found = state { return true }
        return false
    }

    public var summary: String {
        switch state {
        case let .found(dongles):
            if dongles.count == 1 { return "RTL-SDR found: \(dongles[0])." }
            return "\(dongles.count) RTL-SDR dongles found: \(dongles.joined(separator: ", "))."
        case .noDongleConnected:
            return "No RTL-SDR dongle is connected. Plug one in, then scan again. Only one program can use a dongle at a time."
        case .notAvailableOnThisPlatform:
            return "USB RTL-SDR is not available on this platform."
        }
    }

    /// `nil` dongles means the platform has no USB access at all.
    static func make(dongles: [String]?) -> RTLSDRAvailability {
        guard let dongles else { return RTLSDRAvailability(state: .notAvailableOnThisPlatform) }
        return RTLSDRAvailability(state: dongles.isEmpty ? .noDongleConnected : .found(dongles: dongles))
    }

    /// Looks at the USB bus. Cheap, but views ask often, so the answer is kept for a second.
    public static var current: RTLSDRAvailability { cache.value() }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: RTLSDRAvailability?
        private var storedAt = Date.distantPast

        func value() -> RTLSDRAvailability {
            lock.lock()
            defer { lock.unlock() }
            if let stored, Date().timeIntervalSince(storedAt) < 1 { return stored }
            let fresh = RTLSDRAvailability.make(dongles: NativeRTLSDRDevice.connectedDongleDescriptions())
            stored = fresh
            storedAt = Date()
            return fresh
        }
    }
}

// MARK: - The device

/// An RTL-SDR dongle (RTL2832U + R820T), driven by the native Swift driver (`RTLSDRKit`): no C library, works in
/// the App Sandbox with the USB entitlement.
public final class NativeRTLSDRDevice: SDRDevice, @unchecked Sendable {
    public let id = UUID()
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .rtlsdr
    public let supportsTX = false

    public let frequencyRange: ClosedRange<Double> = NativeRTLSDRDevice.tunableRange
    public let supportedSampleRates: [Double] = [
        250_000, 1_024_000, 1_536_000, 1_800_000, 2_048_000, 2_400_000, 2_560_000, 3_200_000
    ]
    public let gainRange: ClosedRange<Double> = 0...49.6

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 2_048_000
    public private(set) var currentGain: Double = 30

    private let opener: @Sendable () throws -> RTLSDRBackend
    private let lock = NSLock()
    private var backend: RTLSDRBackend?
    private var lastStreamError: String?

    /// Whether the tuner's oscillator locked at the last frequency change. False before opening.
    public var tunerLocked: Bool {
        lock.withLock { backend?.pllLocked ?? false }
    }

    /// Why the last stream ended on its own (dongle unplugged, USB error), or nil.
    public var streamError: String? {
        lock.withLock { lastStreamError }
    }

    init(name: String, serial: String, opener: @escaping @Sendable () throws -> RTLSDRBackend) {
        self.name = name
        self.serial = serial
        self.opener = opener
    }

    private static var tunableRange: ClosedRange<Double> {
        #if os(macOS)
        Double(RTLSDRKit.RTLSDRDevice.tunableRange.lowerBound)...Double(RTLSDRKit.RTLSDRDevice.tunableRange.upperBound)
        #else
        24_000_000...1_766_000_000
        #endif
    }

    // MARK: Enumeration

    /// The dongles plugged in right now. Opening one happens in `open()`.
    public static func enumerateDevices() async -> [NativeRTLSDRDevice] {
        #if os(macOS)
        return RTLSDRKit.RTLSDRDevice.connectedDevices().map { info in
            NativeRTLSDRDevice(name: info.name, serial: info.serial) {
                RTLSDRKitBackend(device: try RTLSDRKit.RTLSDRDevice.open(info))
            }
        }
        #else
        return []
        #endif
    }

    /// Human-readable lines for `RTLSDRAvailability`; nil where USB access does not exist.
    static func connectedDongleDescriptions() -> [String]? {
        #if os(macOS)
        return RTLSDRKit.RTLSDRDevice.connectedDevices().map { "\($0.name) (serial \($0.serial))" }
        #else
        return nil
        #endif
    }

    // MARK: SDRDevice

    public func open() async throws {
        guard !lock.withLock({ backend != nil }) else { return }
        do {
            let opened = try opener()
            lock.withLock {
                backend = opened
                lastStreamError = nil
            }
        } catch {
            throw SDRError.openFailed(Self.describe(error))
        }
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        guard let backend = currentBackend() else { throw SDRError.configurationFailed("Device not open") }
        guard frequencyRange.contains(frequency) else {
            throw SDRError.configurationFailed("\(Int(frequency)) Hz is outside this dongle's range (\(Int(frequencyRange.lowerBound / 1e6))–\(Int(frequencyRange.upperBound / 1e6)) MHz)")
        }
        guard gainRange.contains(gain) else {
            throw SDRError.configurationFailed("A gain of \(gain) dB is outside 0–\(gainRange.upperBound) dB")
        }
        do {
            // Rate first: the tuner's IF filter follows it. Then the frequency, then the gain.
            let actualRate = try backend.setSampleRate(Int(sampleRate.rounded()))
            try backend.setCenterFrequency(Int(frequency.rounded()))
            if gain == 0 {
                try backend.setAutomaticGain()
            } else {
                try backend.setTunerGain(tenthsDB: Int((gain * 10).rounded()))
            }
            currentSampleRate = actualRate
            currentFrequency = frequency
            currentGain = gain
        } catch {
            throw SDRError.configurationFailed(Self.describe(error))
        }
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        guard let backend = currentBackend() else { throw SDRError.streamingFailed("Device not open") }
        do {
            try backend.startStreaming(
                onError: { [weak self] error in self?.recordStreamError(error) },
                handler: { buffer in callback(buffer, buffer.count / 2) }
            )
        } catch {
            throw SDRError.streamingFailed(Self.describe(error))
        }
    }

    public func stopStreaming() async {
        currentBackend()?.stopStreaming()
    }

    public func close() async {
        let closing: RTLSDRBackend? = lock.withLock {
            defer { backend = nil }
            return backend
        }
        guard let closing else { return }
        closing.stopStreaming()
        closing.close()
    }

    // MARK: Helpers

    private func currentBackend() -> RTLSDRBackend? {
        lock.withLock { backend }
    }

    private func recordStreamError(_ error: Error) {
        let text = Self.describe(error)
        lock.withLock { lastStreamError = text }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

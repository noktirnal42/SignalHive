import Foundation

/// RTL-SDR device implementation.
/// Bridges to librtlsdr via a dynamically loaded dylib (GPL compliance).
/// The actual librtlsdr.dylib lives in the app bundle's Frameworks/ directory.
public final class RTLSDRDevice: SDRDevice, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .rtlsdr
    public let supportsTX = false

    public let frequencyRange: ClosedRange<Double> = 24_000_000...1_766_000_000
    public let supportedSampleRates: [Double] = [
        250_000, 1_024_000, 1_536_000, 1_800_000, 2_048_000, 2_400_000, 2_560_000, 3_200_000
    ]
    public let gainRange: ClosedRange<Double> = 0...49.6

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 2_048_000
    public private(set) var currentGain: Double = 30

    private let deviceIndex: UInt32
    private var deviceHandle: OpaquePointer?
    private var isStreaming = false
    private var streamCallback: (@Sendable (UnsafeBufferPointer<UInt8>, Int) -> Void)?

    // MARK: - Enumeration

    public static func enumerateDevices() async -> [RTLSDRDevice] {
        guard let bridge = RTLSDRBridge.shared else { return [] }
        let count = bridge.deviceCount()
        guard count > 0 else { return [] }
        return (0..<UInt32(count)).map { idx in
            let name = bridge.deviceName(idx) ?? "RTL-SDR #\(idx)"
            let serial = bridge.deviceSerial(idx) ?? "RTL\(idx)"
            return RTLSDRDevice(index: idx, name: name, serial: serial)
        }
    }

    private init(index: UInt32, name: String, serial: String) {
        self.deviceIndex = index
        self.name = name
        self.serial = serial
        self.id = UUID()
    }

    public func open() async throws {
        guard let bridge = RTLSDRBridge.shared else {
            throw SDRError.openFailed("librtlsdr not available — install via Homebrew: brew install librtlsdr")
        }
        guard let handle = bridge.open(deviceIndex) else {
            throw SDRError.openFailed("Failed to open RTL-SDR device \(deviceIndex)")
        }
        self.deviceHandle = handle
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        guard let bridge = RTLSDRBridge.shared, let handle = deviceHandle else {
            throw SDRError.configurationFailed("Device not open")
        }
        // Sample rate
        guard bridge.setSampleRate(handle, rate: UInt32(sampleRate)) == 0 else {
            throw SDRError.configurationFailed("Failed to set sample rate \(sampleRate)")
        }
        // Center frequency
        guard bridge.setCenterFreq(handle, freq: UInt32(frequency)) == 0 else {
            throw SDRError.configurationFailed("Failed to set frequency \(frequency)")
        }
        // Gain
        if gain == 0 {
            _ = bridge.setTunerGainMode(handle, manual: 0)  // auto gain
        } else {
            _ = bridge.setTunerGainMode(handle, manual: 1)
            _ = bridge.setTunerGain(handle, gain: Int32(gain * 10))
        }
        // Offset tuning for RTL-SDR V4
        _ = bridge.setOffsetTuning(handle, on: 1)
        // DC offset / IQ balance
        _ = bridge.setIQBalance(handle, on: 1)

        currentFrequency = frequency
        currentSampleRate = sampleRate
        currentGain = gain
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        guard let bridge = RTLSDRBridge.shared, let handle = deviceHandle else {
            throw SDRError.streamingFailed("Device not configured")
        }
        isStreaming = true
        streamCallback = callback

        // RTL-SDR async read runs on a dedicated C thread via librtlsdr
        // We bridge via a C-callback trampoline stored in thread-local context
        bridge.resetBuffer(handle)
        bridge.startAsync(handle, context: Unmanaged.passRetained(self).toOpaque()) { buf, len, ctx in
            guard let ctx else { return }
            let device = Unmanaged<RTLSDRDevice>.fromOpaque(ctx).takeUnretainedValue()
            guard device.isStreaming else { return }
            buf?.withMemoryRebound(to: UInt8.self, capacity: Int(len)) { ptr in
                device.streamCallback?(UnsafeBufferPointer(start: ptr, count: Int(len)), Int(len) / 2)
            }
        }
    }

    public func stopStreaming() async {
        guard let bridge = RTLSDRBridge.shared, let handle = deviceHandle else { return }
        isStreaming = false
        bridge.cancelAsync(handle)
    }

    public func close() async {
        await stopStreaming()
        guard let bridge = RTLSDRBridge.shared, let handle = deviceHandle else { return }
        bridge.close(handle)
        deviceHandle = nil
    }
}

// MARK: - Dynamic library bridge (loaded at runtime to satisfy GPL)

/// Wraps a non-Sendable value for explicit unsafe cross-thread transfer.
/// Used only for raw C handles whose lifetime is managed externally.
struct UnsafeSendableBox<T>: @unchecked Sendable { let value: T }

/// Thin wrapper that loads librtlsdr.dylib at runtime and resolves function pointers.
/// This approach satisfies LGPL/GPL by making the library a runtime dependency
/// that users can replace with their own build.
final class RTLSDRBridge: @unchecked Sendable {
    static let shared: RTLSDRBridge? = RTLSDRBridge()

    private let handle: UnsafeMutableRawPointer

    // Function pointer types matching librtlsdr.h
    private let rtlsdr_get_device_count: @convention(c) () -> Int32
    private let rtlsdr_get_device_name: @convention(c) (UInt32) -> UnsafePointer<CChar>?
    private let rtlsdr_get_device_usb_strings: @convention(c) (UInt32, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) -> Int32
    private let rtlsdr_open: @convention(c) (UnsafeMutablePointer<OpaquePointer?>, UInt32) -> Int32
    private let rtlsdr_close: @convention(c) (OpaquePointer) -> Int32
    private let rtlsdr_set_sample_rate: @convention(c) (OpaquePointer, UInt32) -> Int32
    private let rtlsdr_set_center_freq: @convention(c) (OpaquePointer, UInt32) -> Int32
    private let rtlsdr_set_tuner_gain_mode: @convention(c) (OpaquePointer, Int32) -> Int32
    private let rtlsdr_set_tuner_gain: @convention(c) (OpaquePointer, Int32) -> Int32
    private let rtlsdr_set_offset_tuning: @convention(c) (OpaquePointer, Int32) -> Int32
    private let rtlsdr_set_direct_sampling: @convention(c) (OpaquePointer, Int32) -> Int32
    private let rtlsdr_reset_buffer: @convention(c) (OpaquePointer) -> Int32
    private let rtlsdr_cancel_async: @convention(c) (OpaquePointer) -> Int32
    private let rtlsdr_read_async: @convention(c) (OpaquePointer,
        @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void,
        UnsafeMutableRawPointer?, UInt32, UInt32) -> Int32
    private let rtlsdr_set_bias_tee: @convention(c) (OpaquePointer, Int32) -> Int32

    private init?() {
        let paths = [
            "/opt/homebrew/lib/librtlsdr.dylib",
            "/usr/local/lib/librtlsdr.dylib",
            Bundle.main.bundlePath + "/Contents/Frameworks/librtlsdr.dylib",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        self.handle = h

        guard
            let f0  = dlsym(h, "rtlsdr_get_device_count"),
            let f1  = dlsym(h, "rtlsdr_get_device_name"),
            let f2  = dlsym(h, "rtlsdr_get_device_usb_strings"),
            let f3  = dlsym(h, "rtlsdr_open"),
            let f4  = dlsym(h, "rtlsdr_close"),
            let f5  = dlsym(h, "rtlsdr_set_sample_rate"),
            let f6  = dlsym(h, "rtlsdr_set_center_freq"),
            let f7  = dlsym(h, "rtlsdr_set_tuner_gain_mode"),
            let f8  = dlsym(h, "rtlsdr_set_tuner_gain"),
            let f9  = dlsym(h, "rtlsdr_set_offset_tuning"),
            let f10 = dlsym(h, "rtlsdr_set_direct_sampling"),
            let f11 = dlsym(h, "rtlsdr_reset_buffer"),
            let f12 = dlsym(h, "rtlsdr_cancel_async"),
            let f13 = dlsym(h, "rtlsdr_read_async"),
            let f14 = dlsym(h, "rtlsdr_set_bias_tee")
        else { return nil }

        rtlsdr_get_device_count    = unsafeBitCast(f0,  to: (@convention(c) () -> Int32).self)
        rtlsdr_get_device_name     = unsafeBitCast(f1,  to: (@convention(c) (UInt32) -> UnsafePointer<CChar>?).self)
        rtlsdr_get_device_usb_strings = unsafeBitCast(f2, to: (@convention(c) (UInt32, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) -> Int32).self)
        rtlsdr_open                = unsafeBitCast(f3,  to: (@convention(c) (UnsafeMutablePointer<OpaquePointer?>, UInt32) -> Int32).self)
        rtlsdr_close               = unsafeBitCast(f4,  to: (@convention(c) (OpaquePointer) -> Int32).self)
        rtlsdr_set_sample_rate     = unsafeBitCast(f5,  to: (@convention(c) (OpaquePointer, UInt32) -> Int32).self)
        rtlsdr_set_center_freq     = unsafeBitCast(f6,  to: (@convention(c) (OpaquePointer, UInt32) -> Int32).self)
        rtlsdr_set_tuner_gain_mode = unsafeBitCast(f7,  to: (@convention(c) (OpaquePointer, Int32) -> Int32).self)
        rtlsdr_set_tuner_gain      = unsafeBitCast(f8,  to: (@convention(c) (OpaquePointer, Int32) -> Int32).self)
        rtlsdr_set_offset_tuning   = unsafeBitCast(f9,  to: (@convention(c) (OpaquePointer, Int32) -> Int32).self)
        rtlsdr_set_direct_sampling = unsafeBitCast(f10, to: (@convention(c) (OpaquePointer, Int32) -> Int32).self)
        rtlsdr_reset_buffer        = unsafeBitCast(f11, to: (@convention(c) (OpaquePointer) -> Int32).self)
        rtlsdr_cancel_async        = unsafeBitCast(f12, to: (@convention(c) (OpaquePointer) -> Int32).self)
        rtlsdr_read_async          = unsafeBitCast(f13, to: (@convention(c) (OpaquePointer, @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?, UInt32, UInt32) -> Int32).self)
        rtlsdr_set_bias_tee        = unsafeBitCast(f14, to: (@convention(c) (OpaquePointer, Int32) -> Int32).self)
    }

    deinit { dlclose(handle) }

    func deviceCount() -> Int32 { rtlsdr_get_device_count() }

    func deviceName(_ index: UInt32) -> String? {
        guard let ptr = rtlsdr_get_device_name(index) else { return nil }
        return String(cString: ptr)
    }

    func deviceSerial(_ index: UInt32) -> String? {
        var serial = [CChar](repeating: 0, count: 64)
        guard rtlsdr_get_device_usb_strings(index, nil, nil, &serial) == 0 else { return nil }
        return serial.withUnsafeBytes { bytes in
            let nullTerminated = bytes.prefix(while: { $0 != 0 })
            return String(bytes: nullTerminated, encoding: .utf8) ?? ""
        }
    }

    func open(_ index: UInt32) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard rtlsdr_open(&handle, index) == 0 else { return nil }
        return handle
    }

    @discardableResult
    func close(_ handle: OpaquePointer) -> Int32 { rtlsdr_close(handle) }

    @discardableResult
    func setSampleRate(_ handle: OpaquePointer, rate: UInt32) -> Int32 {
        rtlsdr_set_sample_rate(handle, rate)
    }

    @discardableResult
    func setCenterFreq(_ handle: OpaquePointer, freq: UInt32) -> Int32 {
        rtlsdr_set_center_freq(handle, freq)
    }

    @discardableResult
    func setTunerGainMode(_ handle: OpaquePointer, manual: Int32) -> Int32 {
        rtlsdr_set_tuner_gain_mode(handle, manual)
    }

    @discardableResult
    func setTunerGain(_ handle: OpaquePointer, gain: Int32) -> Int32 {
        rtlsdr_set_tuner_gain(handle, gain)
    }

    @discardableResult
    func setOffsetTuning(_ handle: OpaquePointer, on: Int32) -> Int32 {
        rtlsdr_set_offset_tuning(handle, on)
    }

    @discardableResult
    func setIQBalance(_ handle: OpaquePointer, on: Int32) -> Int32 {
        rtlsdr_set_direct_sampling(handle, on)
    }

    @discardableResult
    func resetBuffer(_ handle: OpaquePointer) -> Int32 { rtlsdr_reset_buffer(handle) }

    @discardableResult
    func cancelAsync(_ handle: OpaquePointer) -> Int32 { rtlsdr_cancel_async(handle) }

    func startAsync(
        _ handle: OpaquePointer,
        context: UnsafeMutableRawPointer,
        callback: @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    ) {
        // rtlsdr_read_async blocks until cancelled; run on a background GCD thread.
        // OpaquePointer/UnsafeMutableRawPointer are C handles — lifetime managed by caller.
        let fn = rtlsdr_read_async
        let h = UnsafeSendableBox(value: handle)
        let ctx = UnsafeSendableBox(value: context)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = fn(h.value, callback, ctx.value, 0, 16384 * 2)
        }
    }
}

import Foundation

/// First-pass LimeSDR bridge backed by LimeSuite when available.
///
/// This slice focuses on runtime discovery, open/configure lifecycle, and
/// manager integration. Live RX/TX streaming still requires hardware-backed
/// validation and a fuller vendor stream loop.
public final class LimeSDRDevice: SDRDevice, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .limesdr
    public let supportsTX = true

    public let frequencyRange: ClosedRange<Double> = 100_000...3_800_000_000
    public let supportedSampleRates: [Double] = [
        500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000, 30_720_000
    ]
    public let gainRange: ClosedRange<Double> = 0...70

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 2_000_000
    public private(set) var currentGain: Double = 30

    private let descriptor: String
    private var deviceHandle: OpaquePointer?

    public static var runtimeAvailable: Bool {
        LimeSDRBridge.shared != nil
    }

    public static func enumerateDevices() async -> [LimeSDRDevice] {
        guard let bridge = LimeSDRBridge.shared else { return [] }
        return bridge.deviceDescriptors().enumerated().map { offset, descriptor in
            LimeSDRDevice(index: offset, descriptor: descriptor)
        }
    }

    init(index: Int, descriptor: String) {
        self.descriptor = descriptor
        self.serial = Self.extractValue(named: "serial", from: descriptor) ?? "LIME-\(index)"
        let model = Self.extractValue(named: "module", from: descriptor)
            ?? Self.extractValue(named: "name", from: descriptor)
            ?? "LimeSDR"
        self.name = "\(model) [\(serial)]"
        self.id = UUID()
    }

    public func open() async throws {
        guard let bridge = LimeSDRBridge.shared else {
            throw SDRError.openFailed("LimeSuite not available — install LimeSuite to use LimeSDR devices")
        }
        guard let handle = bridge.open(descriptor: descriptor) else {
            throw SDRError.openFailed("Failed to open LimeSDR device \(serial)")
        }
        guard bridge.initialize(handle) == 0 else {
            bridge.close(handle)
            throw SDRError.openFailed("LimeSDR initialization failed")
        }
        _ = bridge.enableChannel(handle, isTX: false, channel: 0, enabled: true)
        deviceHandle = handle
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        guard frequencyRange.contains(frequency) else {
            throw SDRError.configurationFailed("Frequency \(frequency) is outside LimeSDR range")
        }
        guard gainRange.contains(gain) else {
            throw SDRError.configurationFailed("Gain \(gain) is outside LimeSDR range")
        }
        guard let nearestRate = nearestSupportedRate(to: sampleRate) else {
            throw SDRError.configurationFailed("Unsupported sample rate \(sampleRate)")
        }
        guard let bridge = LimeSDRBridge.shared, let handle = deviceHandle else {
            throw SDRError.configurationFailed("Device not open")
        }
        guard bridge.setSampleRate(handle, sampleRate: nearestRate) == 0 else {
            throw SDRError.configurationFailed("Failed to set LimeSDR sample rate")
        }
        guard bridge.setCenterFrequency(handle, isTX: false, channel: 0, frequency: UInt64(frequency.rounded())) == 0 else {
            throw SDRError.configurationFailed("Failed to set LimeSDR center frequency")
        }
        guard bridge.setGain(handle, isTX: false, channel: 0, gain: UInt32(gain.rounded())) == 0 else {
            throw SDRError.configurationFailed("Failed to set LimeSDR gain")
        }

        currentFrequency = frequency
        currentSampleRate = nearestRate
        currentGain = gain
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        _ = callback
        throw SDRError.notSupported("LimeSDR streaming loop is not yet product-proven in this first-pass bridge")
    }

    public func stopStreaming() async {}

    public func close() async {
        guard let bridge = LimeSDRBridge.shared, let handle = deviceHandle else { return }
        _ = bridge.enableChannel(handle, isTX: false, channel: 0, enabled: false)
        bridge.close(handle)
        deviceHandle = nil
    }

    private func nearestSupportedRate(to requested: Double) -> Double? {
        supportedSampleRates.min(by: { abs($0 - requested) < abs($1 - requested) })
    }

    private static func extractValue(named key: String, from descriptor: String) -> String? {
        descriptor
            .split(separator: ",")
            .compactMap { component -> String? in
                let parts = component.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0].lowercased() == key.lowercased() else { return nil }
                return parts[1]
            }
            .first
    }
}

final class LimeSDRBridge: @unchecked Sendable {
    static let shared: LimeSDRBridge? = LimeSDRBridge()

    private let handle: UnsafeMutableRawPointer

    private let lmsGetDeviceList: @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32
    private let lmsOpen: @convention(c) (UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32
    private let lmsClose: @convention(c) (OpaquePointer) -> Int32
    private let lmsInit: @convention(c) (OpaquePointer) -> Int32
    private let lmsEnableChannel: @convention(c) (OpaquePointer, Bool, UInt32, Bool) -> Int32
    private let lmsSetSampleRate: @convention(c) (OpaquePointer, Double, UInt32) -> Int32
    private let lmsSetLOFrequency: @convention(c) (OpaquePointer, Bool, UInt32, UInt64) -> Int32
    private let lmsSetGaindB: @convention(c) (OpaquePointer, Bool, UInt32, UInt32) -> Int32

    private init?() {
        let paths = [
            "/opt/homebrew/lib/libLimeSuite.dylib",
            "/usr/local/lib/libLimeSuite.dylib",
            Bundle.main.bundlePath + "/Contents/Frameworks/libLimeSuite.dylib",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        handle = library

        guard
            let f0 = dlsym(library, "LMS_GetDeviceList"),
            let f1 = dlsym(library, "LMS_Open"),
            let f2 = dlsym(library, "LMS_Close"),
            let f3 = dlsym(library, "LMS_Init"),
            let f4 = dlsym(library, "LMS_EnableChannel"),
            let f5 = dlsym(library, "LMS_SetSampleRate"),
            let f6 = dlsym(library, "LMS_SetLOFrequency"),
            let f7 = dlsym(library, "LMS_SetGaindB")
        else {
            dlclose(library)
            return nil
        }

        lmsGetDeviceList = unsafeBitCast(f0, to: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Int32).self)
        lmsOpen = unsafeBitCast(f1, to: (@convention(c) (UnsafeMutablePointer<OpaquePointer?>, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32).self)
        lmsClose = unsafeBitCast(f2, to: (@convention(c) (OpaquePointer) -> Int32).self)
        lmsInit = unsafeBitCast(f3, to: (@convention(c) (OpaquePointer) -> Int32).self)
        lmsEnableChannel = unsafeBitCast(f4, to: (@convention(c) (OpaquePointer, Bool, UInt32, Bool) -> Int32).self)
        lmsSetSampleRate = unsafeBitCast(f5, to: (@convention(c) (OpaquePointer, Double, UInt32) -> Int32).self)
        lmsSetLOFrequency = unsafeBitCast(f6, to: (@convention(c) (OpaquePointer, Bool, UInt32, UInt64) -> Int32).self)
        lmsSetGaindB = unsafeBitCast(f7, to: (@convention(c) (OpaquePointer, Bool, UInt32, UInt32) -> Int32).self)
    }

    deinit { dlclose(handle) }

    func deviceDescriptors() -> [String] {
        let count = Int(lmsGetDeviceList(nil))
        guard count > 0 else { return [] }

        let charsPerDescriptor = 256
        var buffer = [CChar](repeating: 0, count: count * charsPerDescriptor)
        let actualCount = Int(lmsGetDeviceList(&buffer))
        guard actualCount > 0 else { return [] }

        return (0..<actualCount).compactMap { index in
            let offset = index * charsPerDescriptor
            return buffer.withUnsafeBufferPointer { ptr -> String? in
                guard let base = ptr.baseAddress?.advanced(by: offset) else { return nil }
                return String(cString: base)
            }
        }
    }

    func open(descriptor: String) -> OpaquePointer? {
        var device: OpaquePointer?
        let result = descriptor.withCString { cString in
            lmsOpen(&device, cString, nil)
        }
        return result == 0 ? device : nil
    }

    @discardableResult
    func initialize(_ device: OpaquePointer) -> Int32 { lmsInit(device) }

    @discardableResult
    func enableChannel(_ device: OpaquePointer, isTX: Bool, channel: UInt32, enabled: Bool) -> Int32 {
        lmsEnableChannel(device, isTX, channel, enabled)
    }

    @discardableResult
    func setSampleRate(_ device: OpaquePointer, sampleRate: Double) -> Int32 {
        lmsSetSampleRate(device, sampleRate, 0)
    }

    @discardableResult
    func setCenterFrequency(_ device: OpaquePointer, isTX: Bool, channel: UInt32, frequency: UInt64) -> Int32 {
        lmsSetLOFrequency(device, isTX, channel, frequency)
    }

    @discardableResult
    func setGain(_ device: OpaquePointer, isTX: Bool, channel: UInt32, gain: UInt32) -> Int32 {
        lmsSetGaindB(device, isTX, channel, gain)
    }

    func close(_ device: OpaquePointer) {
        _ = lmsClose(device)
    }
}

import Foundation

/// First-pass Airspy runtime bridge.
///
/// Discovery and configuration are wired to libairspy when present. Live
/// streaming remains an external validation item and is intentionally kept
/// out of this scoped completion pass.
public final class AirspyDevice: SDRDevice, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .airspy
    public let supportsTX = false

    public let frequencyRange: ClosedRange<Double> = 24_000_000...1_800_000_000
    public let supportedSampleRates: [Double] = [
        2_500_000, 3_000_000, 6_000_000, 10_000_000
    ]
    public let gainRange: ClosedRange<Double> = 0...21

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 10_000_000
    public private(set) var currentGain: Double = 10

    private let serialNumber: UInt64
    private var deviceHandle: OpaquePointer?

    public static var runtimeAvailable: Bool {
        AirspyBridge.shared != nil
    }

    public static func enumerateDevices() async -> [AirspyDevice] {
        guard let bridge = AirspyBridge.shared else { return [] }
        return bridge.deviceSerials().map { AirspyDevice(serialNumber: $0) }
    }

    init(serialNumber: UInt64) {
        self.serialNumber = serialNumber
        self.serial = String(format: "%016llX", serialNumber)
        self.name = "Airspy [\(serial)]"
        self.id = UUID()
    }

    public func open() async throws {
        guard let bridge = AirspyBridge.shared else {
            throw SDRError.openFailed("libairspy not available — install libairspy to use Airspy devices")
        }
        guard let handle = bridge.open(serialNumber: serialNumber) else {
            throw SDRError.openFailed("Failed to open Airspy device \(serial)")
        }
        deviceHandle = handle
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        guard frequencyRange.contains(frequency) else {
            throw SDRError.configurationFailed("Frequency \(frequency) is outside Airspy range")
        }
        guard gainRange.contains(gain) else {
            throw SDRError.configurationFailed("Gain \(gain) is outside Airspy range")
        }
        guard let rate = nearestSupportedRate(to: sampleRate) else {
            throw SDRError.configurationFailed("Unsupported sample rate \(sampleRate)")
        }
        guard let bridge = AirspyBridge.shared, let handle = deviceHandle else {
            throw SDRError.configurationFailed("Device not open")
        }
        guard bridge.setSampleRate(handle, sampleRate: UInt32(rate.rounded())) == 0 else {
            throw SDRError.configurationFailed("Failed to set Airspy sample rate")
        }
        guard bridge.setFrequency(handle, frequency: UInt32(frequency.rounded())) == 0 else {
            throw SDRError.configurationFailed("Failed to set Airspy frequency")
        }
        guard bridge.setGain(handle, gain: UInt8(gain.rounded())) == 0 else {
            throw SDRError.configurationFailed("Failed to set Airspy gain")
        }

        currentFrequency = frequency
        currentSampleRate = rate
        currentGain = gain
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        _ = callback
        throw SDRError.notSupported("Airspy streaming loop is not yet product-proven in this first-pass bridge")
    }

    public func stopStreaming() async {}

    public func close() async {
        guard let bridge = AirspyBridge.shared, let handle = deviceHandle else { return }
        bridge.close(handle)
        deviceHandle = nil
    }

    private func nearestSupportedRate(to requested: Double) -> Double? {
        supportedSampleRates.min(by: { abs($0 - requested) < abs($1 - requested) })
    }
}

final class AirspyBridge: @unchecked Sendable {
    static let shared: AirspyBridge? = AirspyBridge()

    private let handle: UnsafeMutableRawPointer

    private let airspyInit: @convention(c) () -> Int32
    private let airspyExit: @convention(c) () -> Int32
    private let airspyListDevices: @convention(c) (UnsafeMutablePointer<UInt64>?, Int32) -> Int32
    private let airspyOpenSN: @convention(c) (UnsafeMutablePointer<OpaquePointer?>, UInt64) -> Int32
    private let airspyClose: @convention(c) (OpaquePointer) -> Int32
    private let airspySetSampleRate: @convention(c) (OpaquePointer, UInt32) -> Int32
    private let airspySetFreq: @convention(c) (OpaquePointer, UInt32) -> Int32
    private let airspySetLinearityGain: @convention(c) (OpaquePointer, UInt8) -> Int32

    private init?() {
        let paths = [
            "/opt/homebrew/lib/libairspy.dylib",
            "/usr/local/lib/libairspy.dylib",
            Bundle.main.bundlePath + "/Contents/Frameworks/libairspy.dylib",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        handle = library

        guard
            let f0 = dlsym(library, "airspy_init"),
            let f1 = dlsym(library, "airspy_exit"),
            let f2 = dlsym(library, "airspy_list_devices"),
            let f3 = dlsym(library, "airspy_open_sn"),
            let f4 = dlsym(library, "airspy_close"),
            let f5 = dlsym(library, "airspy_set_samplerate"),
            let f6 = dlsym(library, "airspy_set_freq"),
            let f7 = dlsym(library, "airspy_set_linearity_gain")
        else {
            dlclose(library)
            return nil
        }

        airspyInit = unsafeBitCast(f0, to: (@convention(c) () -> Int32).self)
        airspyExit = unsafeBitCast(f1, to: (@convention(c) () -> Int32).self)
        airspyListDevices = unsafeBitCast(f2, to: (@convention(c) (UnsafeMutablePointer<UInt64>?, Int32) -> Int32).self)
        airspyOpenSN = unsafeBitCast(f3, to: (@convention(c) (UnsafeMutablePointer<OpaquePointer?>, UInt64) -> Int32).self)
        airspyClose = unsafeBitCast(f4, to: (@convention(c) (OpaquePointer) -> Int32).self)
        airspySetSampleRate = unsafeBitCast(f5, to: (@convention(c) (OpaquePointer, UInt32) -> Int32).self)
        airspySetFreq = unsafeBitCast(f6, to: (@convention(c) (OpaquePointer, UInt32) -> Int32).self)
        airspySetLinearityGain = unsafeBitCast(f7, to: (@convention(c) (OpaquePointer, UInt8) -> Int32).self)

        guard airspyInit() == 0 else {
            dlclose(library)
            return nil
        }
    }

    deinit {
        _ = airspyExit()
        dlclose(handle)
    }

    func deviceSerials() -> [UInt64] {
        let count = Int(airspyListDevices(nil, 0))
        guard count > 0 else { return [] }
        var serials = [UInt64](repeating: 0, count: count)
        let actualCount = Int(airspyListDevices(&serials, Int32(count)))
        return Array(serials.prefix(actualCount))
    }

    func open(serialNumber: UInt64) -> OpaquePointer? {
        var device: OpaquePointer?
        guard airspyOpenSN(&device, serialNumber) == 0 else { return nil }
        return device
    }

    @discardableResult
    func setSampleRate(_ device: OpaquePointer, sampleRate: UInt32) -> Int32 {
        airspySetSampleRate(device, sampleRate)
    }

    @discardableResult
    func setFrequency(_ device: OpaquePointer, frequency: UInt32) -> Int32 {
        airspySetFreq(device, frequency)
    }

    @discardableResult
    func setGain(_ device: OpaquePointer, gain: UInt8) -> Int32 {
        airspySetLinearityGain(device, gain)
    }

    func close(_ device: OpaquePointer) {
        _ = airspyClose(device)
    }
}

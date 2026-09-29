import Foundation

/// First-pass SDRPlay bridge.
///
/// The proprietary API is discovered dynamically when installed by the user.
/// This pass wires device discovery plus open/config lifecycle into the HAL
/// without claiming hardware validation that we do not yet have.
public final class SDRPlayDevice: SDRDevice, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .sdrplay
    public let supportsTX = false

    public let frequencyRange: ClosedRange<Double> = 1_000...2_000_000_000
    public let supportedSampleRates: [Double] = [
        200_000, 500_000, 1_000_000, 2_000_000, 4_000_000, 6_000_000, 8_000_000, 10_000_000
    ]
    public let gainRange: ClosedRange<Double> = 0...59

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 2_000_000
    public private(set) var currentGain: Double = 30

    private let deviceIndex: UInt32
    private var bridgeOpen = false

    public static var runtimeAvailable: Bool {
        SDRPlayBridge.shared != nil
    }

    public static func enumerateDevices() async -> [SDRPlayDevice] {
        guard let bridge = SDRPlayBridge.shared else { return [] }
        return bridge.devices().enumerated().map { offset, device in
            SDRPlayDevice(index: UInt32(offset), serial: device.serial, model: device.model)
        }
    }

    init(index: UInt32, serial: String, model: String) {
        self.deviceIndex = index
        self.serial = serial
        self.name = "\(model) [\(serial)]"
        self.id = UUID()
    }

    public func open() async throws {
        guard let bridge = SDRPlayBridge.shared else {
            throw SDRError.openFailed("SDRPlay API not available — install SDRPlay API v3 to use SDRPlay devices")
        }
        guard bridge.open() == 0 else {
            throw SDRError.openFailed("Failed to open SDRPlay API")
        }
        bridgeOpen = true
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        guard frequencyRange.contains(frequency) else {
            throw SDRError.configurationFailed("Frequency \(frequency) is outside SDRPlay range")
        }
        guard gainRange.contains(gain) else {
            throw SDRError.configurationFailed("Gain \(gain) is outside SDRPlay range")
        }
        guard let rate = nearestSupportedRate(to: sampleRate) else {
            throw SDRError.configurationFailed("Unsupported sample rate \(sampleRate)")
        }
        guard bridgeOpen else {
            throw SDRError.configurationFailed("Device not open")
        }

        currentFrequency = frequency
        currentSampleRate = rate
        currentGain = gain
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        _ = callback
        throw SDRError.notSupported("SDRPlay streaming loop is not yet product-proven in this first-pass bridge")
    }

    public func stopStreaming() async {}

    public func close() async {
        guard let bridge = SDRPlayBridge.shared, bridgeOpen else { return }
        _ = bridge.close()
        bridgeOpen = false
    }

    private func nearestSupportedRate(to requested: Double) -> Double? {
        supportedSampleRates.min(by: { abs($0 - requested) < abs($1 - requested) })
    }
}

final class SDRPlayBridge: @unchecked Sendable {
    struct DeviceInfo {
        let serial: String
        let model: String
    }

    static let shared: SDRPlayBridge? = SDRPlayBridge()

    private let handle: UnsafeMutableRawPointer

    private let apiOpen: @convention(c) () -> Int32
    private let apiClose: @convention(c) () -> Int32
    private let apiGetDevices: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>, UInt32) -> Int32

    private init?() {
        let paths = [
            "/Library/SDRplayAPI/lib/libsdrplay_api.dylib",
            "/opt/homebrew/lib/libsdrplay_api.dylib",
            "/usr/local/lib/libsdrplay_api.dylib",
            Bundle.main.bundlePath + "/Contents/Frameworks/libsdrplay_api.dylib",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        handle = library

        guard
            let f0 = dlsym(library, "sdrplay_api_Open"),
            let f1 = dlsym(library, "sdrplay_api_Close"),
            let f2 = dlsym(library, "sdrplay_api_GetDevices")
        else {
            dlclose(library)
            return nil
        }

        apiOpen = unsafeBitCast(f0, to: (@convention(c) () -> Int32).self)
        apiClose = unsafeBitCast(f1, to: (@convention(c) () -> Int32).self)
        apiGetDevices = unsafeBitCast(f2, to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>, UInt32) -> Int32).self)
    }

    deinit { dlclose(handle) }

    func devices() -> [DeviceInfo] {
        var count: UInt32 = 0
        guard apiGetDevices(nil, &count, 0) == 0, count > 0 else { return [] }
        var raw = [SDRPlayRawDevice](repeating: .init(), count: Int(count))
        let result = raw.withUnsafeMutableBytes { bytes in
            apiGetDevices(bytes.baseAddress, &count, count)
        }
        guard result == 0 else { return [] }

        return raw.prefix(Int(count)).enumerated().map { index, device in
            let serial = withUnsafeBytes(of: device.serNo) { bytes -> String in
                let chars = bytes.bindMemory(to: CChar.self)
                return String(cString: chars.baseAddress!)
            }
            let model = device.hwVer == 0 ? "SDRPlay" : "SDRPlay RSP\(device.hwVer)"
            return DeviceInfo(serial: serial.isEmpty ? "SDRPLAY-\(index)" : serial, model: model)
        }
    }

    @discardableResult
    func open() -> Int32 { apiOpen() }

    @discardableResult
    func close() -> Int32 { apiClose() }
}

private struct SDRPlayRawDevice {
    var SerNo: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
    var hwVer: UInt8
    var tuner: UInt8
    var rspDuoMode: UInt8
    var reserved: UInt8

    init() {
        SerNo = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        hwVer = 0
        tuner = 0
        rspDuoMode = 0
        reserved = 0
    }

    var serNo: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) {
        SerNo
    }
}

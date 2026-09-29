import Foundation

/// First-pass PlutoSDR bridge backed by libiio when present.
///
/// The current implementation intentionally stops at discovery plus open/config
/// lifecycle so the driver participates in scan flows without pretending the
/// live RX loop has already been validated.
public final class PlutoSDRDevice: SDRDevice, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .plutosdr
    public let supportsTX = true

    public let frequencyRange: ClosedRange<Double> = 325_000_000...3_800_000_000
    public let supportedSampleRates: [Double] = [
        520_834, 1_000_000, 2_000_000, 2_500_000, 5_000_000, 10_000_000, 20_000_000
    ]
    public let gainRange: ClosedRange<Double> = 0...73

    public private(set) var currentFrequency: Double = 1_000_000_000
    public private(set) var currentSampleRate: Double = 2_000_000
    public private(set) var currentGain: Double = 40

    private let uri: String
    private var contextHandle: OpaquePointer?

    public static var runtimeAvailable: Bool {
        PlutoSDRBridge.shared != nil
    }

    public static func enumerateDevices() async -> [PlutoSDRDevice] {
        guard let bridge = PlutoSDRBridge.shared else { return [] }
        return bridge.discoveredURIs().map { PlutoSDRDevice(uri: $0) }
    }

    init(uri: String) {
        self.uri = uri
        self.serial = uri
        self.name = "PlutoSDR [\(uri)]"
        self.id = UUID()
    }

    public func open() async throws {
        guard let bridge = PlutoSDRBridge.shared else {
            throw SDRError.openFailed("libiio not available — install libiio to use PlutoSDR devices")
        }
        guard let context = bridge.createContext(uri: uri) else {
            throw SDRError.openFailed("Failed to create PlutoSDR context for \(uri)")
        }
        contextHandle = context
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        guard frequencyRange.contains(frequency) else {
            throw SDRError.configurationFailed("Frequency \(frequency) is outside PlutoSDR range")
        }
        guard gainRange.contains(gain) else {
            throw SDRError.configurationFailed("Gain \(gain) is outside PlutoSDR range")
        }
        guard let rate = nearestSupportedRate(to: sampleRate) else {
            throw SDRError.configurationFailed("Unsupported sample rate \(sampleRate)")
        }
        guard contextHandle != nil else {
            throw SDRError.configurationFailed("Device not open")
        }

        // The AD9361 attribute write path is intentionally deferred until live
        // hardware validation is available; for now we keep the bridge honest
        // about discovered/opened devices and persist validated operator intent.
        currentFrequency = frequency
        currentSampleRate = rate
        currentGain = gain
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        _ = callback
        throw SDRError.notSupported("PlutoSDR streaming loop is not yet product-proven in this first-pass bridge")
    }

    public func stopStreaming() async {}

    public func close() async {
        guard let bridge = PlutoSDRBridge.shared, let context = contextHandle else { return }
        bridge.destroyContext(context)
        contextHandle = nil
    }

    private func nearestSupportedRate(to requested: Double) -> Double? {
        supportedSampleRates.min(by: { abs($0 - requested) < abs($1 - requested) })
    }
}

final class PlutoSDRBridge: @unchecked Sendable {
    static let shared: PlutoSDRBridge? = PlutoSDRBridge()

    private let handle: UnsafeMutableRawPointer

    private let iioCreateDefaultContext: @convention(c) () -> OpaquePointer?
    private let iioCreateContextFromURI: @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
    private let iioContextDestroy: @convention(c) (OpaquePointer) -> Void

    private init?() {
        let paths = [
            "/opt/homebrew/lib/libiio.dylib",
            "/usr/local/lib/libiio.dylib",
            Bundle.main.bundlePath + "/Contents/Frameworks/libiio.dylib",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        handle = library

        guard
            let f0 = dlsym(library, "iio_create_default_context"),
            let f1 = dlsym(library, "iio_create_context_from_uri"),
            let f2 = dlsym(library, "iio_context_destroy")
        else {
            dlclose(library)
            return nil
        }

        iioCreateDefaultContext = unsafeBitCast(f0, to: (@convention(c) () -> OpaquePointer?).self)
        iioCreateContextFromURI = unsafeBitCast(f1, to: (@convention(c) (UnsafePointer<CChar>) -> OpaquePointer?).self)
        iioContextDestroy = unsafeBitCast(f2, to: (@convention(c) (OpaquePointer) -> Void).self)
    }

    deinit { dlclose(handle) }

    func discoveredURIs() -> [String] {
        guard let context = iioCreateDefaultContext() else { return [] }
        iioContextDestroy(context)
        return ["local:"]
    }

    func createContext(uri: String) -> OpaquePointer? {
        uri.withCString { iioCreateContextFromURI($0) }
    }

    func destroyContext(_ context: OpaquePointer) {
        iioContextDestroy(context)
    }
}

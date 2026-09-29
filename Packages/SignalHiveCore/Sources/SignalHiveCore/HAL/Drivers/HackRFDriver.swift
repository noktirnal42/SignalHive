import Foundation

/// HackRF One device driver. Bridges to libhackrf via runtime dylib loading.
public final class HackRFDevice: SDRDevice, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .hackrf
    public let supportsTX = true

    public let frequencyRange: ClosedRange<Double> = 1_000_000...6_000_000_000
    public let supportedSampleRates: [Double] = [
        2_000_000, 4_000_000, 8_000_000, 10_000_000, 12_500_000, 16_000_000, 20_000_000
    ]
    public let gainRange: ClosedRange<Double> = 0...62

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 8_000_000
    public private(set) var currentGain: Double = 20

    private var deviceHandle: OpaquePointer?
    private var isStreaming = false
    private var streamCallback: (@Sendable (UnsafeBufferPointer<UInt8>, Int) -> Void)?

    public static func enumerateDevices() async -> [HackRFDevice] {
        guard HackRFBridge.shared != nil else { return [] }
        // libhackrf supports single device enumeration; multi-device via serial
        return [HackRFDevice(serial: "HACKRF-0")]
    }

    private init(serial: String) {
        self.serial = serial
        self.name = "HackRF One [\(serial)]"
        self.id = UUID()
    }

    public func open() async throws {
        guard let bridge = HackRFBridge.shared else {
            throw SDRError.openFailed("libhackrf not available — install via Homebrew: brew install hackrf")
        }
        guard let handle = bridge.open() else {
            throw SDRError.openFailed("Failed to open HackRF device")
        }
        self.deviceHandle = handle
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        guard let bridge = HackRFBridge.shared, let handle = deviceHandle else {
            throw SDRError.configurationFailed("Device not open")
        }
        guard bridge.setSampleRate(handle, rate: sampleRate) == 0 else {
            throw SDRError.configurationFailed("Failed to set sample rate")
        }
        guard bridge.setFrequency(handle, freq: UInt64(frequency)) == 0 else {
            throw SDRError.configurationFailed("Failed to set frequency")
        }
        // LNA gain (0–40 dB in 8 dB steps) and VGA gain (0–62 dB in 2 dB steps)
        let lnaGain = min(40, (UInt32(gain / 2) * 8))
        let vgaGain = min(62, UInt32(gain) * 2)
        _ = bridge.setLNAGain(handle, gain: lnaGain)
        _ = bridge.setVGAGain(handle, gain: vgaGain)
        _ = bridge.setAmpEnable(handle, enable: gain > 20 ? 1 : 0)

        currentFrequency = frequency
        currentSampleRate = sampleRate
        currentGain = gain
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        guard let bridge = HackRFBridge.shared, let handle = deviceHandle else {
            throw SDRError.streamingFailed("Device not configured")
        }
        isStreaming = true
        streamCallback = callback

        bridge.startRX(handle, context: Unmanaged.passRetained(self).toOpaque()) { rawPtr in
            guard let rawPtr else { return 0 }
            // Bind raw pointer to hackrf_transfer struct layout
            let transfer = rawPtr.assumingMemoryBound(to: hackrf_transfer.self).pointee
            guard let ctx = transfer.rx_ctx else { return 0 }
            let device = Unmanaged<HackRFDevice>.fromOpaque(ctx).takeUnretainedValue()
            guard device.isStreaming else { return 0 }
            let buf = transfer.buffer
            let len = Int(transfer.valid_length)
            buf?.withMemoryRebound(to: UInt8.self, capacity: len) { ptr in
                device.streamCallback?(UnsafeBufferPointer(start: ptr, count: len), len / 2)
            }
            return 0
        }
    }

    public func stopStreaming() async {
        guard let bridge = HackRFBridge.shared, let handle = deviceHandle else { return }
        isStreaming = false
        _ = bridge.stopRX(handle)
    }

    public func close() async {
        await stopStreaming()
        guard let bridge = HackRFBridge.shared, let handle = deviceHandle else { return }
        _ = bridge.close(handle)
        deviceHandle = nil
    }

    public func transmit(samples: [ComplexFloat]) async throws {
        // HackRF TX implementation: convert ComplexFloat → int8, transmit block
        guard let bridge = HackRFBridge.shared, let handle = deviceHandle else {
            throw SDRError.notSupported("Device not open")
        }
        var raw = [Int8](repeating: 0, count: samples.count * 2)
        for (i, s) in samples.enumerated() {
            raw[i * 2]     = Int8(max(-128, min(127, Int(s.i * 128))))
            raw[i * 2 + 1] = Int8(max(-128, min(127, Int(s.q * 128))))
        }
        try await bridge.transmitBlock(handle, samples: raw)
    }
}

// MARK: - HackRF transfer structure (mirrors hackrf.h hackrf_transfer)
// Layout matches the C struct exactly so we can bind raw pointers to it.

private struct hackrf_transfer {
    var device: OpaquePointer?
    var buffer: UnsafeMutablePointer<UInt8>?
    var buffer_length: Int32
    var valid_length: Int32
    var rx_ctx: UnsafeMutableRawPointer?
    var tx_ctx: UnsafeMutableRawPointer?
}

// C-compatible callback type: receives a raw pointer to hackrf_transfer,
// cast manually inside the closure. Using raw pointer avoids Obj-C
// representability issues with Swift-defined struct types.
fileprivate typealias HackRFRxCallback = @convention(c) (UnsafeMutableRawPointer?) -> Int32
fileprivate typealias HackRFStartFn = @convention(c) (OpaquePointer, HackRFRxCallback?, UnsafeMutableRawPointer?) -> Int32

// MARK: - Bridge

final class HackRFBridge: @unchecked Sendable {
    static let shared: HackRFBridge? = HackRFBridge()

    private let handle: UnsafeMutableRawPointer

    private let hackrf_init: @convention(c) () -> Int32
    private let hackrf_open: @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Int32
    private let hackrf_close: @convention(c) (OpaquePointer) -> Int32
    private let hackrf_set_sample_rate: @convention(c) (OpaquePointer, Double) -> Int32
    private let hackrf_set_freq: @convention(c) (OpaquePointer, UInt64) -> Int32
    private let hackrf_set_lna_gain: @convention(c) (OpaquePointer, UInt32) -> Int32
    private let hackrf_set_vga_gain: @convention(c) (OpaquePointer, UInt32) -> Int32
    private let hackrf_set_amp_enable: @convention(c) (OpaquePointer, UInt8) -> Int32
    private let hackrf_start_rx: HackRFStartFn
    private let hackrf_stop_rx: @convention(c) (OpaquePointer) -> Int32
    private let hackrf_start_tx: HackRFStartFn
    private let hackrf_stop_tx: @convention(c) (OpaquePointer) -> Int32

    private init?() {
        let paths = [
            "/opt/homebrew/lib/libhackrf.dylib",
            "/usr/local/lib/libhackrf.dylib",
            Bundle.main.bundlePath + "/Contents/Frameworks/libhackrf.dylib",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        self.handle = h

        guard
            let f0 = dlsym(h, "hackrf_init"),
            let f1 = dlsym(h, "hackrf_open"),
            let f2 = dlsym(h, "hackrf_close"),
            let f3 = dlsym(h, "hackrf_set_sample_rate"),
            let f4 = dlsym(h, "hackrf_set_freq"),
            let f5 = dlsym(h, "hackrf_set_lna_gain"),
            let f6 = dlsym(h, "hackrf_set_vga_gain"),
            let f7 = dlsym(h, "hackrf_set_amp_enable"),
            let f8 = dlsym(h, "hackrf_start_rx"),
            let f9 = dlsym(h, "hackrf_stop_rx"),
            let f10 = dlsym(h, "hackrf_start_tx"),
            let f11 = dlsym(h, "hackrf_stop_tx")
        else { return nil }

        hackrf_init = unsafeBitCast(f0, to: (@convention(c) () -> Int32).self)
        hackrf_open = unsafeBitCast(f1, to: (@convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Int32).self)
        hackrf_close = unsafeBitCast(f2, to: (@convention(c) (OpaquePointer) -> Int32).self)
        hackrf_set_sample_rate = unsafeBitCast(f3, to: (@convention(c) (OpaquePointer, Double) -> Int32).self)
        hackrf_set_freq = unsafeBitCast(f4, to: (@convention(c) (OpaquePointer, UInt64) -> Int32).self)
        hackrf_set_lna_gain = unsafeBitCast(f5, to: (@convention(c) (OpaquePointer, UInt32) -> Int32).self)
        hackrf_set_vga_gain = unsafeBitCast(f6, to: (@convention(c) (OpaquePointer, UInt32) -> Int32).self)
        hackrf_set_amp_enable = unsafeBitCast(f7, to: (@convention(c) (OpaquePointer, UInt8) -> Int32).self)
        hackrf_start_rx = unsafeBitCast(f8, to: HackRFStartFn.self)
        hackrf_stop_rx = unsafeBitCast(f9, to: (@convention(c) (OpaquePointer) -> Int32).self)
        hackrf_start_tx = unsafeBitCast(f10, to: HackRFStartFn.self)
        hackrf_stop_tx = unsafeBitCast(f11, to: (@convention(c) (OpaquePointer) -> Int32).self)

        _ = hackrf_init()
    }

    deinit { dlclose(handle) }

    func open() -> OpaquePointer? {
        var handle: OpaquePointer?
        guard hackrf_open(&handle) == 0 else { return nil }
        return handle
    }

    @discardableResult
    func close(_ h: OpaquePointer) -> Int32 { hackrf_close(h) }

    @discardableResult
    func setSampleRate(_ h: OpaquePointer, rate: Double) -> Int32 { hackrf_set_sample_rate(h, rate) }

    @discardableResult
    func setFrequency(_ h: OpaquePointer, freq: UInt64) -> Int32 { hackrf_set_freq(h, freq) }

    @discardableResult
    func setLNAGain(_ h: OpaquePointer, gain: UInt32) -> Int32 { hackrf_set_lna_gain(h, gain) }

    @discardableResult
    func setVGAGain(_ h: OpaquePointer, gain: UInt32) -> Int32 { hackrf_set_vga_gain(h, gain) }

    @discardableResult
    func setAmpEnable(_ h: OpaquePointer, enable: UInt8) -> Int32 { hackrf_set_amp_enable(h, enable) }

    fileprivate func startRX(
        _ h: OpaquePointer,
        context: UnsafeMutableRawPointer,
        callback: HackRFRxCallback
    ) {
        let start = hackrf_start_rx
        let hBox = UnsafeSendableBox(value: h)
        let ctxBox = UnsafeSendableBox(value: context)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = start(hBox.value, callback, ctxBox.value)
        }
    }

    @discardableResult
    func stopRX(_ h: OpaquePointer) -> Int32 { hackrf_stop_rx(h) }

    func transmitBlock(_ h: OpaquePointer, samples: [Int8]) async throws {
        // Simplified: for real TX you'd set up a transfer buffer callback
        // This is a placeholder showing the API surface
        throw SDRError.notSupported("TX callback setup not yet implemented")
    }
}

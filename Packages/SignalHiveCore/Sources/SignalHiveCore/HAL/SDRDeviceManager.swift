import Foundation

/// Manages discovery, connection, and lifecycle of all SDR devices.
@MainActor
public final class SDRDeviceManager: ObservableObject {
    typealias ScanProvider = @Sendable () async -> [any SDRDevice]

    public static let shared = SDRDeviceManager()

    @Published public private(set) var availableDevices: [any SDRDevice] = []
    @Published public private(set) var activeDevices: [any SDRDevice] = []
    @Published public private(set) var isScanning = false

    public let maxActiveDevices = 4

    private var activePipelines: [UUID: DSPPipeline] = [:]
    private var scanProviders: [ScanProvider]

    private init() {
        self.scanProviders = Self.defaultScanProviders()

        // TestSignalDevice is always available without touching USB. Hardware scanning is user-triggered.
        availableDevices = [TestSignalDevice()]

        // Restore saved network devices without initializing USB stack
        appendPersistedNetworkSources(into: &availableDevices)
    }

    // MARK: - Scanning

    /// Scan for all connected SDR hardware and network sources. Called on explicit user request.
    public func scan() async {
        isScanning = true
        defer { isScanning = false }

        var found: [any SDRDevice] = []

        // Always include test signal
        found.append(TestSignalDevice())

        for provider in scanProviders {
            found += await provider()
        }

        // Network SDR (from saved hosts in UserDefaults)
        appendPersistedNetworkSources(into: &found)

        availableDevices = found
    }

    static func defaultScanProviders() -> [ScanProvider] {
        [
            { await NativeRTLSDRDevice.enumerateDevices() },
            { await HackRFDevice.enumerateDevices() },
            { await LimeSDRDevice.enumerateDevices() },
            { await SDRPlayDevice.enumerateDevices() },
            { await AirspyDevice.enumerateDevices() },
            { await PlutoSDRDevice.enumerateDevices() }
        ]
    }

    func setScanProvidersForTesting(_ providers: [ScanProvider]) {
        scanProviders = providers
    }

    func resetScanProvidersForTesting() {
        scanProviders = Self.defaultScanProviders()
    }

    // MARK: - Activation

    public func activate(_ device: any SDRDevice) async throws {
        guard activeDevices.count < maxActiveDevices else {
            throw SDRError.notSupported("Maximum \(maxActiveDevices) simultaneous devices reached")
        }
        guard !activeDevices.contains(where: { $0.id == device.id }) else { return }

        try await device.open()
        activeDevices.append(device)

        let pipeline = DSPPipeline(device: device)
        activePipelines[device.id] = pipeline
    }

    public func deactivate(_ device: any SDRDevice) async {
        guard let idx = activeDevices.firstIndex(where: { $0.id == device.id }) else { return }
        let d = activeDevices.remove(at: idx)
        let pipeline = activePipelines.removeValue(forKey: d.id)
        await pipeline?.stop()
        await d.close()
    }

    /// The active device that is the same hardware as `device`. A rescan makes new device objects (each with a new `id`) for
    /// hardware that is already open, so matching on `id` would offer a dongle the Scanner holds as free again.
    public func activeInstance(matching device: any SDRDevice) -> (any SDRDevice)? {
        let key = DongleRegistry.key(for: device)
        return activeDevices.first { DongleRegistry.key(for: $0) == key }
    }

    public func pipeline(for device: any SDRDevice) -> DSPPipeline? {
        activePipelines[device.id]
    }

    public func deactivateAll() async {
        for device in activeDevices {
            let pipeline = activePipelines.removeValue(forKey: device.id)
            await pipeline?.stop()
            await device.close()
        }
        activeDevices.removeAll()
        activePipelines.removeAll()
    }

    // MARK: - Add network host

    public func addNetworkDevice(host: String, port: Int = 1234) {
        let device = NetworkSDRDevice(host: host, port: port)
        if !availableDevices.contains(where: { $0.id == device.id }) {
            availableDevices.append(device)
        }
        var hosts = UserDefaults.standard.stringArray(forKey: "networkSDRHosts") ?? []
        let entry = "\(host):\(port)"
        if !hosts.contains(entry) {
            hosts.append(entry)
            UserDefaults.standard.set(hosts, forKey: "networkSDRHosts")
        }
    }

    public func addOpenWebRXDevice(urlString: String) {
        let device = OpenWebRXDevice(urlString: urlString)
        if !availableDevices.contains(where: { $0.id == device.id }) {
            availableDevices.append(device)
        }
        var sources = UserDefaults.standard.stringArray(forKey: "openWebRXSources") ?? []
        if !sources.contains(device.serial) {
            sources.append(device.serial)
            UserDefaults.standard.set(sources, forKey: "openWebRXSources")
        }
    }

    private func appendPersistedNetworkSources(into devices: inout [any SDRDevice]) {
        let networkHosts = UserDefaults.standard.stringArray(forKey: "networkSDRHosts") ?? []
        for entry in networkHosts {
            let parts = entry.split(separator: ":", maxSplits: 1)
            let host = String(parts.first ?? "127.0.0.1")
            let port = parts.count > 1 ? Int(parts[1]) ?? 1234 : 1234
            devices.append(NetworkSDRDevice(host: host, port: port))
        }

        let openWebRXSources = UserDefaults.standard.stringArray(forKey: "openWebRXSources") ?? []
        for source in openWebRXSources {
            devices.append(OpenWebRXDevice(urlString: source))
        }
    }
}

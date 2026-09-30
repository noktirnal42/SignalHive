import SwiftUI
import SignalHiveCore

/// State behind the Air Map and Air Data panels: what is being received, what has been heard, and how the map is set up.
@Observable
@MainActor
final class AviationModel {
    enum Source: String, CaseIterable, Identifiable {
        case demo = "Demo sky"
        case adsb1090 = "RTL-SDR, 1090 MHz ADS-B"
        var id: String { rawValue }
    }

    // What is happening
    private(set) var picture = AviationPicture()
    private(set) var source: Source?
    private(set) var status = "Not receiving"
    private(set) var lastError: String?
    private(set) var health = ReceiverHealth(blocks: 0, frames: 0, secondsSinceLastBlock: nil)
    /// Messages per second over the last few seconds, for the status line.
    private(set) var messageRate = 0.0

    var isRunning: Bool { source != nil }

    // Selection and view settings
    var selectedAircraft: UInt32?
    var showRadar = true
    var showTrails = true
    var showLabels = true
    var showGroundStations = true
    /// How far back trails reach, in minutes.
    var trailMinutes = 10.0
    var searchText = ""
    var messageKinds = Set(AviationMessageKind.allCases)
    var minimumSeverity = AviationSeverity.info
    var latestPerStation = true
    var messageSearch = ""

    /// Where the antenna is; used for range and to place a first position report.
    private(set) var receiverLocation: GeoCoordinate?

    func setReceiverLocation(_ coordinate: GeoCoordinate?) {
        receiverLocation = coordinate
        picture.receiver = coordinate
        let defaults = UserDefaults.standard
        if let coordinate {
            defaults.set(coordinate.latitude, forKey: Keys.latitude)
            defaults.set(coordinate.longitude, forKey: Keys.longitude)
        } else {
            defaults.removeObject(forKey: Keys.latitude)
            defaults.removeObject(forKey: Keys.longitude)
        }
    }

    // Cached drawing inputs, rebuilt when the picture changes
    private(set) var radarLayers: [RadarLayer] = []
    private(set) var trails: [UInt32: [TrailSegment]] = [:]
    private var radarRevisions: [RadarProduct: Int] = [:]

    struct RadarLayer: Identifiable {
        var id: RadarProduct { product }
        var product: RadarProduct
        var image: CGImage
        var north: Double
        var south: Double
        var west: Double
        var east: Double
        var observation: String?
    }

    // Sources
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var demo: AviationDemoScenario?
    @ObservationIgnored private var demoRadar: [RadarProduct: RadarMosaic] = [:]
    @ObservationIgnored private var lastDemoRadar = Date.distantPast
    @ObservationIgnored private var previousMessageCount = 0
    @ObservationIgnored private var previousMessageTime = Date()
    #if os(macOS)
    @ObservationIgnored private var receiver: ADSB1090Receiver?
    #endif

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.latitude) != nil {
            let coordinate = GeoCoordinate(latitude: defaults.double(forKey: Keys.latitude), longitude: defaults.double(forKey: Keys.longitude))
            if coordinate.isValid { receiverLocation = coordinate }
        }
        picture.receiver = receiverLocation
    }

    private enum Keys {
        static let latitude = "aviation.receiverLatitude"
        static let longitude = "aviation.receiverLongitude"
    }

    // MARK: Derived

    var selected: AircraftState? {
        selectedAircraft.flatMap { picture.aircraft[$0] }
    }

    var visibleAircraft: [AircraftState] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let all = picture.sortedAircraft
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.displayName.lowercased().contains(needle) || $0.addressHex.lowercased().contains(needle)
                || $0.aircraftClass.displayName.lowercased().contains(needle) || $0.squawk.contains(needle)
        }
    }

    var filteredMessages: [AviationMessage] {
        picture.messages.filtered(kinds: messageKinds, minimumSeverity: minimumSeverity, search: messageSearch,
                                  latestPerStation: latestPerStation)
    }

    /// Where the demo sky is centred: over the antenna if it is known, else the middle of the contiguous US.
    private var demoCentre: GeoCoordinate {
        receiverLocation ?? GeoCoordinate(latitude: 39.1, longitude: -94.6)
    }

    // MARK: Starting and stopping

    func start(_ source: Source) async {
        await stop()
        lastError = nil
        switch source {
        case .demo: startDemo()
        case .adsb1090: await startADSB()
        }
        startMaintenance()
    }

    func stop() async {
        demoTask?.cancel()
        demoTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        #if os(macOS)
        if let receiver { await receiver.stop() }
        receiver = nil
        #endif
        if source != nil { status = "Stopped" }
        source = nil
    }

    func clear() {
        picture.clear()
        picture.receiver = receiverLocation
        rebuildCaches()
        selectedAircraft = nil
    }

    // MARK: Demo

    private func startDemo() {
        source = .demo
        status = "Demo sky: made-up aircraft, storms and reports"
        let scenario = AviationDemoScenario(center: demoCentre)
        demo = scenario
        demoRadar = [:]
        lastDemoRadar = .distantPast
        tickDemo()
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.tickDemo()
            }
        }
    }

    private func tickDemo() {
        guard let demo else { return }
        let now = Date()
        if now.timeIntervalSince(lastDemoRadar) > 30 {
            lastDemoRadar = now
            var mosaic = RadarMosaic(product: .regional)
            for block in demo.radarBlocks(at: now) { mosaic.add(block, at: now) }
            demoRadar = [.regional: mosaic]
        }
        var next = demo.snapshot(at: now)
        next.setRadar(demoRadar)
        picture = next
        rebuildCaches()
    }

    // MARK: Live receiver

    private func startADSB() async {
        #if os(macOS)
        let manager = SDRDeviceManager.shared
        if manager.availableDevices.first(where: { $0.deviceType == .rtlsdr }) == nil {
            status = "Looking for a dongle..."
            await manager.scan()
        }
        guard let device = manager.availableDevices.first(where: { $0.deviceType == .rtlsdr }) else {
            lastError = "No RTL-SDR found. Plug one in, then try again."
            status = "No dongle"
            return
        }
        if manager.activeDevices.contains(where: { $0.id == device.id }) {
            lastError = "The Scanner is using this dongle. Stop it there first; only one program can hold it."
            status = "Dongle busy"
            return
        }
        let receiver = ADSB1090Receiver(device: device, receiverLocation: receiverLocation)
        do {
            try await receiver.start { [weak self] updates in
                Task { @MainActor in self?.receive(updates) }
            }
        } catch {
            lastError = error.localizedDescription
            status = "Could not start"
            return
        }
        self.receiver = receiver
        source = .adsb1090
        status = "Listening on 1090 MHz"
        picture.receiver = receiverLocation
        #else
        lastError = "Live reception needs the Mac app (it drives the dongle over USB)."
        status = "Not available on this device"
        #endif
    }

    private func receive(_ updates: [AviationUpdate]) {
        guard source == .adsb1090 else { return }
        picture.apply(updates)
        rebuildCaches()
    }

    // MARK: Housekeeping

    private func startMaintenance() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.maintain()
            }
        }
    }

    private func maintain() async {
        let now = Date()
        if source == .adsb1090 {
            picture.expire(now: now)
            rebuildCaches()
            #if os(macOS)
            if let receiver {
                health = await receiver.health()
                if let silence = health.secondsSinceLastBlock, silence > 4 {
                    status = "No samples from the dongle for \(Int(silence)) s"
                } else if health.blocks > 0 {
                    status = "Listening on 1090 MHz: \(health.frames) frames decoded"
                }
            }
            #endif
        }
        let count = picture.stats.messages
        let elapsed = now.timeIntervalSince(previousMessageTime)
        if elapsed > 0.5 {
            messageRate = max(0, Double(count - previousMessageCount) / elapsed)
            previousMessageCount = count
            previousMessageTime = now
        }
        if let selectedAircraft, picture.aircraft[selectedAircraft] == nil { self.selectedAircraft = nil }
    }

    // MARK: Caches

    /// Rebuilds the radar images (only for mosaics that changed) and the trail pieces.
    private func rebuildCaches() {
        var layers: [RadarLayer] = []
        for product in RadarProduct.allCases {
            guard let mosaic = picture.radar[product] else { radarRevisions[product] = nil; continue }
            if radarRevisions[product] == mosaic.revision, let existing = radarLayers.first(where: { $0.product == product }) {
                layers.append(existing)
                continue
            }
            radarRevisions[product] = mosaic.revision
            if let raster = mosaic.raster(), let image = raster.makeCGImage() {
                layers.append(RadarLayer(product: product, image: image, north: raster.north, south: raster.south,
                                         west: raster.west, east: raster.east, observation: mosaic.latestObservationLabel))
            }
        }
        radarLayers = layers

        guard showTrails else { trails = [:]; return }
        let now = Date()
        let window = trailMinutes * 60
        var built: [UInt32: [TrailSegment]] = [:]
        for state in picture.positionedAircraft {
            let pieces = TrailBuilder.segments(from: state.history.samples, now: now, window: window)
            if !pieces.isEmpty { built[state.address] = pieces }
        }
        trails = built
    }

    /// Call after changing a layer setting that affects the caches.
    func settingsChanged() {
        rebuildCaches()
    }
}

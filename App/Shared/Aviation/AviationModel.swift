import SwiftUI
import CoreLocation
import SignalHiveCore

/// State behind the Air Map and Air Data panels: what is being received, what has been heard, and how the map is set up.
@Observable
@MainActor
final class AviationModel {
    enum Source: String, CaseIterable, Identifiable {
        case demo = "Demo sky"
        case adsb1090 = "1090 MHz ADS-B"
        case uat978 = "978 MHz UAT and FIS-B weather"
        var id: String { rawValue }

        var isLive: Bool { self != .demo }

        var detail: String {
            switch self {
            case .demo: return "Made-up aircraft, storms and reports, to try the map without an antenna."
            case .adsb1090: return "Airliners and most other aircraft. Needs an RTL-SDR and a 1090 MHz antenna."
            case .uat978: return "US general aviation, plus ground-station weather radar and reports (FIS-B). Needs an RTL-SDR and a 978 MHz antenna."
            }
        }
    }

    // What is happening
    private(set) var picture = AviationPicture()
    private(set) var activeSources: Set<Source> = []
    private(set) var statuses: [Source: String] = [:]
    private(set) var errors: [Source: String] = [:]
    private(set) var healths: [Source: ReceiverHealth] = [:]
    /// Which dongle each live source is using, by name.
    private(set) var deviceNames: [Source: String] = [:]
    /// Messages per second over the last few seconds, for the status line.
    private(set) var messageRate = 0.0

    var isRunning: Bool { !activeSources.isEmpty }
    var isDemo: Bool { activeSources.contains(.demo) }
    var liveSources: [Source] { Source.allCases.filter(\.isLive) }

    /// One line for the status pill.
    var status: String {
        let ordered = Source.allCases.filter { activeSources.contains($0) }
        if ordered.isEmpty { return errors.values.first ?? "Not receiving" }
        return ordered.map { statuses[$0] ?? $0.rawValue }.joined(separator: " \u{00B7} ")
    }

    var lastError: String? {
        Source.allCases.compactMap { errors[$0] }.first
    }

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
    private(set) var locationStatus = "Manual position"
    private(set) var locationError: String?
    @ObservationIgnored private lazy var locationService = ReceiverLocationService { [weak self] coordinate in
        self?.setReceiverLocation(coordinate)
        self?.locationStatus = "From Location Services"
        self?.locationError = nil
    } onError: { [weak self] message in
        self?.locationError = message
        self?.locationStatus = "Location unavailable"
    }

    func setReceiverLocation(_ coordinate: GeoCoordinate?) {
        receiverLocation = coordinate
        picture.receiver = coordinate
        locationError = nil
        locationStatus = coordinate == nil ? "Manual position" : "Manual position set"
        let restart1090 = activeSources.contains(.adsb1090)
        let defaults = UserDefaults.standard
        if let coordinate {
            defaults.set(coordinate.latitude, forKey: Keys.latitude)
            defaults.set(coordinate.longitude, forKey: Keys.longitude)
        } else {
            defaults.removeObject(forKey: Keys.latitude)
            defaults.removeObject(forKey: Keys.longitude)
        }
        if restart1090 {
            statuses[.adsb1090] = "Restarting 1090 MHz with receiver location"
            Task { [weak self] in await self?.restartLiveSource(.adsb1090) }
        }
    }

    func requestLocationServices() {
        locationStatus = "Requesting location..."
        locationService.requestLocation()
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
    @ObservationIgnored private var receiver1090: ADSB1090Receiver?
    @ObservationIgnored private var receiver978: UAT978Receiver?
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
        errors[source] = nil
        if source == .demo {
            await stopLiveSources()
            startDemo()
        } else {
            if activeSources.contains(.demo) {
                await stop(.demo)
                picture.clear()
                picture.receiver = receiverLocation
                rebuildCaches()
            }
            await startLive(source)
        }
        startMaintenanceIfNeeded()
    }

    func stop(_ source: Source) async {
        switch source {
        case .demo:
            demoTask?.cancel()
            demoTask = nil
            demo = nil
        case .adsb1090:
            #if os(macOS)
            if let receiver1090 { await receiver1090.stop() }
            receiver1090 = nil
            #endif
        case .uat978:
            #if os(macOS)
            if let receiver978 { await receiver978.stop() }
            receiver978 = nil
            #endif
        }
        if activeSources.contains(source) { statuses[source] = "Stopped" }
        activeSources.remove(source)
        deviceNames[source] = nil
        DongleRegistry.shared.releaseAll(owner: Self.owner(of: source))
        if activeSources.isEmpty {
            maintenanceTask?.cancel()
            maintenanceTask = nil
        }
    }

    func stopAll() async {
        for source in Source.allCases { await stop(source) }
    }

    private func stopLiveSources() async {
        for source in Source.allCases where source.isLive { await stop(source) }
    }

    private func restartLiveSource(_ source: Source) async {
        guard source.isLive, activeSources.contains(source) else { return }
        await stop(source)
        await startLive(source)
        startMaintenanceIfNeeded()
    }

    func clear() {
        picture.clear()
        picture.receiver = receiverLocation
        rebuildCaches()
        selectedAircraft = nil
    }

    // MARK: Demo

    private func startDemo() {
        activeSources.insert(.demo)
        statuses[.demo] = "Demo sky: made-up aircraft, storms and reports"
        let scenario = AviationDemoScenario(center: demoCentre)
        demo = scenario
        demoRadar = [:]
        lastDemoRadar = .distantPast
        tickDemo()
        demoTask?.cancel()
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

    /// The name this source claims a dongle under.
    private static func owner(of source: Source) -> String {
        "Air Map (\(source.rawValue))"
    }

    // MARK: Live receivers

    private func startLive(_ source: Source) async {
        #if os(macOS)
        let manager = SDRDeviceManager.shared
        if !manager.availableDevices.contains(where: { $0.deviceType == .rtlsdr }) {
            statuses[source] = "Looking for a dongle..."
            await manager.scan()
        }
        let dongles = manager.availableDevices.filter { $0.deviceType == .rtlsdr }
        guard !dongles.isEmpty else {
            errors[source] = "No RTL-SDR found. Plug one in, then try again."
            statuses[source] = "No dongle"
            return
        }
        // A dongle another source (here, the Scanner or the Decoder Hub) holds is not free.
        let registry = DongleRegistry.shared
        guard let device = registry.firstFree(in: dongles, for: Self.owner(of: source)) else {
            errors[source] = registry.busyExplanation(for: dongles)
            statuses[source] = "No free dongle"
            return
        }
        do {
            try registry.claim(device, owner: Self.owner(of: source))
        } catch {
            errors[source] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statuses[source] = "No free dongle"
            return
        }
        let label = device.name + " " + device.serial
        let updateHandler: @Sendable ([AviationUpdate]) -> Void = { [weak self] updates in
            Task { @MainActor in self?.receive(updates) }
        }
        do {
            switch source {
            case .adsb1090:
                let receiver = ADSB1090Receiver(device: device, receiverLocation: receiverLocation)
                try await receiver.start(onUpdates: updateHandler)
                receiver1090 = receiver
                statuses[source] = "Listening on 1090 MHz"
            case .uat978:
                let receiver = UAT978Receiver(device: device)
                try await receiver.start(onUpdates: updateHandler)
                receiver978 = receiver
                statuses[source] = "Listening on 978 MHz"
            case .demo:
                return
            }
        } catch {
            DongleRegistry.shared.release(device, owner: Self.owner(of: source))
            errors[source] = error.localizedDescription
            statuses[source] = "Could not start"
            return
        }
        deviceNames[source] = label
        activeSources.insert(source)
        picture.receiver = receiverLocation
        #else
        errors[source] = "Live reception needs the Mac app (it drives the dongle over USB)."
        statuses[source] = "Not available on this device"
        #endif
    }

    private func receive(_ updates: [AviationUpdate]) {
        guard activeSources.contains(where: \.isLive) else { return }
        picture.apply(updates)
        rebuildCaches()
    }

    // MARK: Housekeeping

    private func startMaintenanceIfNeeded() {
        guard maintenanceTask == nil, isRunning else { return }
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
        if activeSources.contains(where: \.isLive) {
            picture.expire(now: now)
            rebuildCaches()
            #if os(macOS)
            if let receiver1090 {
                let health = await receiver1090.health()
                healths[.adsb1090] = health
                statuses[.adsb1090] = Self.statusText(band: "1090 MHz", health: health)
            }
            if let receiver978 {
                let health = await receiver978.health()
                healths[.uat978] = health
                statuses[.uat978] = Self.statusText(band: "978 MHz", health: health)
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

    private static func statusText(band: String, health: ReceiverHealth) -> String {
        if let silence = health.secondsSinceLastBlock, silence > 4 {
            return "\(band): no samples from the dongle for \(Int(silence)) s"
        }
        if health.blocks == 0 { return "\(band): starting" }
        return "\(band): \(AviationFormat.grouped(health.frames)) frames"
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

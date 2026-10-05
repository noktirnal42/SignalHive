import SwiftUI
import MapKit
import SignalHiveCore

// MARK: - Map

/// ADS-B and FIS-B on a map: aircraft as painted icons colored by altitude, trails that show where each one has been and
/// how high it was, and NEXRAD weather radar. The text side of the same data lives in Air Data.
struct AirMapView: View {
    @Environment(AviationModel.self) private var model
    @Namespace private var mapScope
    @State private var camera: MapCameraPosition = .region(AirMapView.startRegion)
    @State private var styleChoice = MapStyleChoice.dark
    @State private var showTraffic = false
    @State private var showPointsOfInterest = false
    @State private var showAppleMapControls = true
    @State private var showSidebar = true
    @State private var placedCamera = false

    enum MapStyleChoice: String, CaseIterable, Identifiable {
        case dark = "Dark"
        case standard = "Map"
        case terrain = "Terrain"
        case satellite = "Satellite"
        case hybrid = "Hybrid"
        case hybridTerrain = "Hybrid Terrain"
        var id: String { rawValue }

        var shortTitle: String {
            switch self {
            case .dark: "Dark"
            case .standard: "Map"
            case .terrain: "Topo"
            case .satellite: "Sat"
            case .hybrid: "Hyb"
            case .hybridTerrain: "3D"
            }
        }

        var symbol: String {
            switch self {
            case .dark: "moon.stars"
            case .standard: "map"
            case .terrain: "mountain.2"
            case .satellite: "globe.americas"
            case .hybrid: "map.fill"
            case .hybridTerrain: "mountain.2.fill"
            }
        }

        var supportsRoadOverlays: Bool { self != .satellite }

        func style(showTraffic: Bool, showPointsOfInterest: Bool) -> MapStyle {
            let pointsOfInterest: PointOfInterestCategories = showPointsOfInterest ? .all : .excludingAll
            switch self {
            case .dark:
                return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: pointsOfInterest, showsTraffic: showTraffic)
            case .standard:
                return .standard(elevation: .flat, emphasis: .automatic, pointsOfInterest: pointsOfInterest, showsTraffic: showTraffic)
            case .terrain:
                return .standard(elevation: .realistic, emphasis: .automatic, pointsOfInterest: pointsOfInterest, showsTraffic: showTraffic)
            case .satellite:
                return .imagery(elevation: .realistic)
            case .hybrid:
                return .hybrid(elevation: .flat, pointsOfInterest: pointsOfInterest, showsTraffic: showTraffic)
            case .hybridTerrain:
                return .hybrid(elevation: .realistic, pointsOfInterest: pointsOfInterest, showsTraffic: showTraffic)
            }
        }
    }

    private static let startRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.1, longitude: -94.6),
        span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 12))

    var body: some View {
        HStack(spacing: 0) {
            mapArea
            if showSidebar {
                Divider()
                AirSidebar(model: model, centerOn: centerOn)
                    .frame(width: 340)
            }
        }
        .background(HiveInk.graphite)
        .preferredColorScheme(.dark)
        .navigationTitle("Air Map")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Map mode", selection: $styleChoice) {
                        ForEach(MapStyleChoice.allCases) { choice in
                            Label(choice.rawValue, systemImage: choice.symbol).tag(choice)
                        }
                    }
                    Divider()
                    Toggle("Show traffic", isOn: $showTraffic)
                        .disabled(!styleChoice.supportsRoadOverlays)
                    Toggle("Show points of interest", isOn: $showPointsOfInterest)
                        .disabled(!styleChoice.supportsRoadOverlays)
                    Divider()
                    Toggle("Apple map controls", isOn: $showAppleMapControls)
                } label: {
                    Label(styleChoice.rawValue, systemImage: styleChoice.symbol)
                }
                Button {
                    fitToTraffic()
                } label: {
                    Label("Fit to traffic", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
                Button {
                    showSidebar.toggle()
                } label: {
                    Label("Sidebar", systemImage: "sidebar.right")
                }
            }
        }
        .onAppear { placeCameraOnce() }
        .onChange(of: model.activeSources) { _, _ in fitToTraffic() }
        .onChange(of: model.receiverLocation) { _, location in
            guard let location, model.picture.aircraft.isEmpty else { return }
            centerOn(location)
        }
    }

    private var mapArea: some View {
        GeometryReader { geometry in
            MapReader { proxy in
                Map(position: $camera, interactionModes: .all, scope: mapScope) {
                    if let receiver = model.receiverLocation {
                        Annotation("Antenna", coordinate: CLLocationCoordinate2D(latitude: receiver.latitude, longitude: receiver.longitude),
                                   anchor: .center) {
                            AirMarker(symbol: "antenna.radiowaves.left.and.right", tint: HiveInk.cyan)
                        }
                    }
                    if model.showGroundStations {
                        ForEach(Array(model.picture.groundStations.values)) { station in
                            Annotation("FIS-B ground station",
                                       coordinate: CLLocationCoordinate2D(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude),
                                       anchor: .center) {
                                AirMarker(symbol: "dot.radiowaves.up.forward", tint: HiveInk.mint)
                            }
                        }
                    }
                }
                .mapStyle(styleChoice.style(showTraffic: showTraffic, showPointsOfInterest: showPointsOfInterest))
                .mapControls {
                    if showAppleMapControls {
                        MapUserLocationButton(scope: mapScope)
                        MapCompass(scope: mapScope)
                        MapPitchToggle(scope: mapScope)
                        #if os(macOS)
                        MapPitchSlider(scope: mapScope)
                        #endif
                        MapScaleView(scope: mapScope)
                    }
                }
                .overlay {
                    TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                        if let viewport = MapViewport(proxy: proxy, size: geometry.size) {
                            AirOverlayCanvas(viewport: viewport, now: timeline.date, model: model)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .onTapGesture { location in
                    if let viewport = MapViewport(proxy: proxy, size: geometry.size) {
                        select(at: location, viewport: viewport)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                AirStatusPill(model: model).padding(12)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    AirMapModeStrip(styleChoice: $styleChoice)
                    AirMapGestureHint()
                }
                .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                AirLegend(model: model).padding(12)
            }
            .overlay {
                if !model.isRunning && model.picture.aircraft.isEmpty {
                    AirEmptyState(model: model)
                }
            }
        }
    }

    // MARK: Actions

    private func select(at location: CGPoint, viewport: MapViewport) {
        let now = Date()
        var best: (address: UInt32, distance: Double)?
        for state in model.picture.positionedAircraft {
            guard let coordinate = state.projectedCoordinate(at: now) else { continue }
            let point = viewport.point(for: coordinate)
            let distance = hypot(point.x - Double(location.x), point.y - Double(location.y))
            if distance < 30, distance < (best?.distance ?? Double.infinity) { best = (state.address, distance) }
        }
        model.selectedAircraft = best?.address
    }

    private func placeCameraOnce() {
        guard !placedCamera else { return }
        placedCamera = true
        if model.picture.boundingBox() != nil {
            fitToTraffic()
        } else if let receiver = model.receiverLocation {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: receiver.latitude, longitude: receiver.longitude),
                                                span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 4)))
        }
    }

    private func fitToTraffic() {
        guard let box = model.picture.boundingBox() else { return }
        let latitudeSpan = min(170, max(0.4, (box.north - box.south) * 1.35))
        let longitudeSpan = min(350, max(0.5, (box.east - box.west) * 1.35))
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (box.north + box.south) / 2, longitude: (box.east + box.west) / 2),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)))
    }

    private func centerOn(_ coordinate: GeoCoordinate) {
        camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                            span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.8)))
    }
}

extension MapViewport {
    /// The part of the world a map view shows right now, from the map's own conversion of two opposite corners. The
    /// overlay then does all its conversions with plain arithmetic (see `MapViewport`).
    init?(proxy: MapProxy, size: CGSize) {
        guard size.width > 1, size.height > 1,
              let topLeft = proxy.convert(CGPoint.zero, from: .local),
              let bottomRight = proxy.convert(CGPoint(x: size.width, y: size.height), from: .local) else { return nil }
        self.init(topLeft: GeoCoordinate(latitude: topLeft.latitude, longitude: topLeft.longitude),
                  bottomRight: GeoCoordinate(latitude: bottomRight.latitude, longitude: bottomRight.longitude),
                  width: Double(size.width), height: Double(size.height))
    }
}

private struct AirMarker: View {
    var symbol: String
    var tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(tint)
            .padding(6)
            .background(HiveInk.graphite.opacity(0.85), in: Circle())
            .overlay(Circle().stroke(tint.opacity(0.7), lineWidth: 1))
    }
}

// MARK: - Overlay

/// Draws radar, trails and aircraft over the map. All positions come from one `MapViewport`, computed once per frame.
private struct AirOverlayCanvas: View {
    let viewport: MapViewport
    let now: Date
    let model: AviationModel

    var body: some View {
        // Everything the drawing needs is read here, so the view is redrawn when any of it changes.
        let picture = model.picture
        let trails = model.trails
        let radar = model.radarLayers
        let selected = model.selectedAircraft
        let showRadar = model.showRadar
        let showTrails = model.showTrails
        let showLabels = model.showLabels
        return Canvas { context, size in
            if showRadar { drawRadar(&context, size: size, layers: radar) }
            if showTrails { drawTrails(&context, trails: trails, selected: selected) }
            drawAircraft(&context, picture: picture, selected: selected, showLabels: showLabels)
        }
    }

    // Radar

    private func drawRadar(_ context: inout GraphicsContext, size: CGSize, layers: [AviationModel.RadarLayer]) {
        let canvas = CGRect(origin: .zero, size: size)
        // The wide CONUS mosaic goes underneath, the detailed regional one over it.
        for product in [RadarProduct.conus, .regional] {
            guard let layer = layers.first(where: { $0.product == product }) else { continue }
            let northWest = viewport.point(for: GeoCoordinate(latitude: layer.north, longitude: layer.west))
            let southEast = viewport.point(for: GeoCoordinate(latitude: layer.south, longitude: layer.east))
            let rect = CGRect(x: northWest.x, y: northWest.y, width: southEast.x - northWest.x, height: southEast.y - northWest.y)
            guard rect.width > 1, rect.height > 1, rect.intersects(canvas) else { continue }
            var layerContext = context
            layerContext.opacity = 0.82
            layerContext.draw(Image(decorative: layer.image, scale: 1), in: rect)
        }
    }

    // Trails

    private func drawTrails(_ context: inout GraphicsContext, trails: [UInt32: [TrailSegment]], selected: UInt32?) {
        let margin = 60.0
        for (address, pieces) in trails {
            let isSelected = address == selected
            let dimmed = selected != nil && !isSelected
            let width: CGFloat = isSelected ? 3.2 : 1.7
            for piece in pieces {
                let a = viewport.point(for: piece.from)
                let b = viewport.point(for: piece.to)
                guard (a.x > -margin || b.x > -margin), (a.x < viewport.width + margin || b.x < viewport.width + margin),
                      (a.y > -margin || b.y > -margin), (a.y < viewport.height + margin || b.y < viewport.height + margin) else { continue }
                var path = Path()
                path.move(to: CGPoint(x: a.x, y: a.y))
                path.addLine(to: CGPoint(x: b.x, y: b.y))
                let alpha = piece.alpha * (dimmed ? 0.35 : 0.95)
                context.stroke(path, with: .color(Color(piece.color, opacity: alpha)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
    }

    // Aircraft

    private func iconRadius(_ state: AircraftState) -> CGFloat {
        switch state.aircraftClass {
        case .heavy: return 15
        case .large, .highVortexLarge: return 13.5
        case .small: return 12
        case .rotorcraft: return 12.5
        case .light, .glider, .ultralight: return 11
        case .lighterThanAir, .parachutist: return 10
        case .uav, .pointObstacle, .clusterObstacle, .lineObstacle: return 9
        case .surfaceEmergency, .surfaceService: return 8
        case .highPerformance, .spaceVehicle, .unknown: return 11
        }
    }

    private func drawAircraft(_ context: inout GraphicsContext, picture: AviationPicture, selected: UInt32?, showLabels: Bool) {
        let margin = 50.0
        // Selected and emergency aircraft last, so they are on top.
        let ordered = picture.positionedAircraft.sorted { lhs, rhs in
            let l = (lhs.address == selected ? 2 : 0) + (lhs.isEmergency ? 1 : 0)
            let r = (rhs.address == selected ? 2 : 0) + (rhs.isEmergency ? 1 : 0)
            return l == r ? lhs.address < rhs.address : l < r
        }
        let labelsEverywhere = showLabels && viewport.widthNM < 300
        var labelsLeft = 150
        let pulse = 0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 4)

        for state in ordered {
            guard let coordinate = state.projectedCoordinate(at: now), viewport.contains(coordinate, margin: margin) else { continue }
            let point = viewport.point(for: coordinate)
            let center = CGPoint(x: point.x, y: point.y)
            let radius = iconRadius(state)
            let isSelected = state.address == selected
            let opacity: Double
            switch state.freshness(now: now) {
            case .live: opacity = 1
            case .recent: opacity = 0.75
            case .stale: opacity = 0.4
            }

            if state.isEmergency {
                let ring = radius + 6 + 4 * pulse
                context.stroke(Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                               with: .color(.red.opacity(0.35 + 0.5 * pulse)), style: StrokeStyle(lineWidth: 2))
            }
            AircraftIconRenderer.draw(state.iconKind, in: &context, at: center, headingDegrees: state.trackDegrees ?? 0,
                                      radius: isSelected ? radius * 1.2 : radius, color: state.color, opacity: opacity)
            if isSelected {
                let ring = radius * 1.2 + 7
                context.stroke(Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                               with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }

            if (labelsEverywhere && labelsLeft > 0) || isSelected {
                labelsLeft -= 1
                drawLabel(&context, state: state, at: CGPoint(x: center.x + radius + 5, y: center.y), emphasised: isSelected)
            }
        }
    }

    private func drawLabel(_ context: inout GraphicsContext, state: AircraftState, at point: CGPoint, emphasised: Bool) {
        let name = state.displayName
        let altitude = AviationFormat.altitudeLabel(state.altitudeFeet, onGround: state.onGround)
        var detail = altitude
        if let rate = state.verticalRateFPM, rate > 250 { detail += " \u{2191}" } else if let rate = state.verticalRateFPM, rate < -250 { detail += " \u{2193}" }
        let shadow = Color.black.opacity(0.85)
        let nameText = Text(name).font(.system(size: 10, weight: .bold, design: .monospaced))
        let detailText = Text(detail).font(.system(size: 9, weight: .medium, design: .monospaced))
        for offset in [CGSize(width: 0.8, height: 0.8), CGSize(width: -0.8, height: 0.8)] {
            context.draw(nameText.foregroundStyle(shadow), at: CGPoint(x: point.x + offset.width, y: point.y - 5 + offset.height), anchor: .leading)
            context.draw(detailText.foregroundStyle(shadow), at: CGPoint(x: point.x + offset.width, y: point.y + 6 + offset.height), anchor: .leading)
        }
        context.draw(nameText.foregroundStyle(emphasised ? Color.white : Color.white.opacity(0.92)),
                     at: CGPoint(x: point.x, y: point.y - 5), anchor: .leading)
        context.draw(detailText.foregroundStyle(Color(state.color)), at: CGPoint(x: point.x, y: point.y + 6), anchor: .leading)
    }
}

// MARK: - Chrome

private struct AirStatusPill: View {
    let model: AviationModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isDemo { HiveStatusBadge("DEMO", tint: HiveInk.amber) }
            Circle()
                .fill(model.isRunning ? HiveInk.mint : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .lineLimit(1)
            Text("\(model.picture.aircraft.count) aircraft")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if model.isRunning && !model.isDemo {
                Text(String(format: "%.0f msg/s", model.messageRate))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let radar = model.radarLayers.first, let label = radar.observation {
                Text("Radar \(label)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(HiveInk.cyan)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct AirMapModeStrip: View {
    @Binding var styleChoice: AirMapView.MapStyleChoice

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AirMapView.MapStyleChoice.allCases) { choice in
                Button {
                    styleChoice = choice
                } label: {
                    Label(choice.shortTitle, systemImage: choice.symbol)
                        .labelStyle(.iconOnly)
                        .help(choice.rawValue)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(styleChoice == choice ? HiveInk.graphite : .white.opacity(0.82))
                .frame(width: 30, height: 28)
                .background(styleChoice == choice ? HiveInk.cyan : .white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(styleChoice == choice ? HiveInk.cyan.opacity(0.7) : .white.opacity(0.12), lineWidth: 1)
                }
                .accessibilityLabel("Use \(choice.rawValue) map")
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct AirMapGestureHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.point.up.left")
            Text("Trackpad: pan, pinch, rotate, pitch")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 1))
        .allowsHitTesting(false)
    }
}

private struct AirLegend: View {
    let model: AviationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ALTITUDE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                LinearGradient(
                    stops: AltitudeColorScale.stops.map {
                        Gradient.Stop(color: Color($0.color), location: AltitudeColorScale.legendFraction(feet: $0.feet))
                    },
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: 230, height: 8)
                    .clipShape(Capsule())
                ZStack(alignment: .leading) {
                    ForEach(AltitudeColorScale.legendTicks, id: \.self) { feet in
                        Text(feet == 0 ? "0" : "\(feet / 1000)k")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .offset(x: 230 * AltitudeColorScale.legendFraction(feet: feet) - (feet == 0 ? 0 : 6))
                    }
                }
                .frame(width: 230, height: 11, alignment: .leading)
            }
            if model.showRadar && !model.radarLayers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("RADAR")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        ForEach(RadarPalette.legendLevels, id: \.self) { level in
                            let color = RadarPalette.color(level: level)
                            Rectangle()
                                .fill(Color(RGB8(color.red, color.green, color.blue), opacity: Double(color.alpha) / 255 + 0.1))
                                .frame(width: 36, height: 8)
                        }
                    }
                    .clipShape(Capsule())
                    HStack {
                        Text("light").frame(maxWidth: .infinity, alignment: .leading)
                        Text("heavy")
                        Text("extreme").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 230)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct AirEmptyState: View {
    let model: AviationModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplane")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(HiveInk.cyan)
            Text("No aircraft yet")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text("Listen for real traffic with an RTL-SDR. Use 1090 MHz for airliners and most aircraft; use 978 MHz for US general aviation, TIS-B and FIS-B weather. Set the antenna position first for faster ADS-B position fixes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                #if os(macOS)
                Button {
                    Task { await model.start(.adsb1090) }
                } label: {
                    Label("Listen on 1090 MHz", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await model.start(.uat978) }
                } label: {
                    Label("978 MHz + weather", systemImage: "cloud.sun.rain")
                }
                .buttonStyle(.bordered)
                #endif
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Sidebar

private struct AirSidebar: View {
    @Bindable var model: AviationModel
    var centerOn: (GeoCoordinate) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let selected = model.selected {
                    AircraftDetailPanel(aircraft: selected, model: model, centerOn: centerOn)
                }
                SourcePanel(model: model)
                LayersPanel(model: model)
                AircraftListPanel(model: model)
            }
            .padding(12)
        }
        .background(HiveInk.graphite)
    }
}

private struct SourcePanel: View {
    @Bindable var model: AviationModel
    @State private var positionText = ""
    @State private var positionError = false

    var body: some View {
        HiveInstrumentPanel("Sources", status: model.isRunning ? "running" : "idle") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.liveSources) { source in
                    sourceRow(source)
                }
                HStack {
                    Spacer()
                    Button("Clear everything") { model.clear() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(model.picture.aircraft.isEmpty && model.picture.messages.messages.isEmpty)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Antenna position")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    HStack {
                        TextField("40.1234, -100.5678", text: $positionText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .onSubmit { applyPosition() }
                        Button("Set") { applyPosition() }
                    }
                    HStack(spacing: 8) {
                        Button {
                            model.requestLocationServices()
                        } label: {
                            Label("Use device location", systemImage: "location")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        if model.receiverLocation != nil {
                            Button("Clear") {
                                positionText = ""
                                model.setReceiverLocation(nil)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    if positionError {
                        Text("Type latitude and longitude, like 40.1234, -100.5678.").font(.caption2).foregroundStyle(.red)
                    } else if let error = model.locationError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    } else if let location = model.receiverLocation {
                        Text("\(model.locationStatus): \(AviationFormat.coordinate(location))").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    } else {
                        Text("Unset: ranges are hidden, and a first 1090 MHz position needs an even and an odd report.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .onAppear {
            if let location = model.receiverLocation, positionText.isEmpty {
                positionText = String(format: "%.4f, %.4f", location.latitude, location.longitude)
            }
        }
    }

    private func sourceRow(_ source: AviationModel.Source) -> some View {
        let active = model.activeSources.contains(source)
        #if os(macOS)
        let available = true
        #else
        let available = !source.isLive
        #endif
        let text = active ? (model.statuses[source] ?? "") : source.detail
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle()
                    .fill(active ? HiveInk.mint : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(source.rawValue)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(active ? "Stop" : "Start") {
                    Task {
                        if active { await model.stop(source) } else { await model.start(source) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(active ? Color.red : HiveInk.cyan)
                .disabled(!available)
            }
            Text(text)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            if let device = model.deviceNames[source] {
                Text(device).font(.caption2).foregroundStyle(HiveInk.cyan.opacity(0.8))
            }
            if let error = model.errors[source] {
                Text(error).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !available {
                Text("Live reception needs the Mac app.").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func applyPosition() {
        let trimmed = positionText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setReceiverLocation(nil)
            positionError = false
        } else if let coordinate = GeoCoordinate.parse(trimmed) {
            model.setReceiverLocation(coordinate)
            positionError = false
        } else {
            positionError = true
        }
    }
}

private struct LayersPanel: View {
    @Bindable var model: AviationModel

    var body: some View {
        HiveInstrumentPanel("Layers") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Weather radar", isOn: $model.showRadar)
                Toggle("Trails", isOn: $model.showTrails)
                Toggle("Labels", isOn: $model.showLabels)
                Toggle("Ground stations", isOn: $model.showGroundStations)
                if model.showTrails {
                    HStack {
                        Text("Trail length").font(.caption).foregroundStyle(.white.opacity(0.7))
                        Slider(value: $model.trailMinutes, in: 2...30, step: 1)
                        Text("\(Int(model.trailMinutes)) min")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .onChange(of: model.trailMinutes) { _, _ in model.settingsChanged() }
        .onChange(of: model.showTrails) { _, _ in model.settingsChanged() }
    }
}

private struct AircraftListPanel: View {
    @Bindable var model: AviationModel

    var body: some View {
        let aircraft = model.visibleAircraft
        HiveInstrumentPanel("Aircraft", status: "\(model.picture.aircraft.count)") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search callsign, ICAO, squawk, type", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                if aircraft.isEmpty {
                    Text(model.picture.aircraft.isEmpty ? "Nothing heard yet." : "No aircraft match.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(aircraft.prefix(300)) { state in
                            AircraftRow(state: state, selected: state.address == model.selectedAircraft)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedAircraft = state.address }
                        }
                    }
                    if aircraft.count > 300 {
                        Text("Showing the first 300 of \(aircraft.count).").font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
    }
}

private struct AircraftRow: View {
    let state: AircraftState
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            AircraftIconView(kind: state.iconKind, color: state.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(state.displayName)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                    if state.isEmergency {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(AviationFormat.altitudeLabel(state.altitudeFeet, onGround: state.onGround))
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color(state.color))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? HiveInk.cyan.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var subtitle: String {
        var parts = [state.aircraftClass.displayName + (state.classIsInferred ? "?" : "")]
        if let speed = state.groundSpeedKnots { parts.append(AviationFormat.speed(speed)) }
        if state.coordinate == nil { parts.append("no position") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct AircraftDetailPanel: View {
    let aircraft: AircraftState
    let model: AviationModel
    var centerOn: (GeoCoordinate) -> Void

    var body: some View {
        HiveInstrumentPanel(status: aircraft.freshness(now: Date()) == .live ? "live" : "quiet") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AircraftIconView(kind: aircraft.iconKind, color: aircraft.color, size: 52, heading: aircraft.trackDegrees ?? 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(aircraft.displayName)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                        Text(identity)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Button {
                        model.selectedAircraft = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.5))
                }

                if aircraft.isEmergency {
                    Label(aircraft.squawkAlert?.displayName ?? aircraft.emergency?.label ?? "Emergency", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        metric("ALTITUDE", AviationFormat.altitude(aircraft.altitudeFeet, onGround: aircraft.onGround), tint: Color(aircraft.color))
                        metric("SPEED", AviationFormat.speed(aircraft.groundSpeedKnots))
                    }
                    GridRow {
                        metric("TRACK", AviationFormat.track(aircraft.trackDegrees))
                        metric("CLIMB", AviationFormat.verticalRate(aircraft.verticalRateFPM))
                    }
                    GridRow {
                        metric("SQUAWK", aircraft.squawk.isEmpty ? "\u{2014}" : aircraft.squawk)
                        metric("RANGE", AviationFormat.distance(model.picture.rangeNM(of: aircraft)))
                    }
                    GridRow {
                        metric("HEARD", "\(aircraft.messageCount) msgs")
                        metric("LAST", AviationFormat.age(Date().timeIntervalSince(aircraft.lastSeen)) + " ago")
                    }
                }

                if let position = aircraft.coordinate {
                    Text(AviationFormat.coordinate(position))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .textSelection(.enabled)
                }

                if aircraft.history.samples.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ALTITUDE HISTORY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        AltitudeProfile(samples: aircraft.history.samples)
                        if let range = aircraft.history.altitudeRange {
                            HStack {
                                Text(AviationFormat.altitude(range.lowerBound))
                                Spacer()
                                Text(AviationFormat.altitude(range.upperBound))
                            }
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }

                Text(aircraft.aircraftClass.detail + (aircraft.classIsInferred ? ". Guessed from the flight ID; the aircraft did not say." : ""))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if let position = aircraft.coordinate {
                    Button {
                        centerOn(position)
                    } label: {
                        Label("Center on map", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var identity: String {
        var parts = [aircraft.addressHex]
        if let country = aircraft.country { parts.append(country) }
        if aircraft.isLikelyUSMilitary { parts.append("military block") }
        parts.append(aircraft.aircraftClass.displayName + (aircraft.classIsInferred ? " (guess)" : ""))
        parts.append(aircraft.sources.map(\.displayName).sorted().joined(separator: ", "))
        return parts.joined(separator: " \u{00B7} ")
    }

    private func metric(_ label: String, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Altitude over time for one aircraft, each stretch colored by its altitude like the trail on the map.
private struct AltitudeProfile: View {
    let samples: [TrackSample]

    var body: some View {
        Canvas { context, size in
            let points = samples.compactMap { sample in sample.altitudeFeet.map { (time: sample.time, feet: $0) } }
            guard points.count > 1, let first = points.first, let last = points.last,
                  let low = points.map(\.feet).min(), let high = points.map(\.feet).max() else { return }
            let span = max(1, last.time.timeIntervalSince(first.time))
            let range = Double(max(500, high - low))
            func position(_ point: (time: Date, feet: Int)) -> CGPoint {
                CGPoint(x: size.width * point.time.timeIntervalSince(first.time) / span,
                        y: size.height - 4 - (size.height - 8) * Double(point.feet - low) / range)
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(.white.opacity(0.15)), lineWidth: 1)
            for index in 1..<points.count {
                var path = Path()
                path.move(to: position(points[index - 1]))
                path.addLine(to: position(points[index]))
                let feet = Double(points[index - 1].feet + points[index].feet) / 2
                context.stroke(path, with: .color(Color(AltitudeColorScale.color(forFeet: feet))),
                               style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
        .frame(height: 64)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

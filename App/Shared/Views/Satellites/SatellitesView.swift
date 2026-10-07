import SwiftUI
import UniformTypeIdentifiers
import SignalHiveCore

/// Satellite passes: when a satellite is above the horizon for your antenna, how good a chance each pass is with the
/// antennas you have, and where to point. Prediction only. Nothing here records or decodes a pass yet, and the screen
/// does not offer to.
struct SatellitesView: View {
    @Environment(AppModel.self) private var app
    @Environment(AviationModel.self) private var aviation
    @State private var model = SatellitesModel()
    @State private var observerText = ""
    @State private var showAntennas = false
    @State private var showImporter = false

    var body: some View {
        ZStack {
            HiveWorkbenchBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    controls
                    filters
                    notices
                    content
                }
                .padding(24)
                .frame(maxWidth: 1180, alignment: .leading)
            }
        }
        .navigationTitle("Satellites")
        .task {
            if let location = aviation.receiverLocation { observerText = Self.text(location) }
            await model.start(database: app.userDatabase, location: aviation.receiverLocation)
        }
        .onChange(of: aviation.receiverLocation) { _, location in
            if let location { observerText = Self.text(location) }
            model.setObserver(location)
        }
        .onChange(of: model.state.filters.horizonHours) { _, _ in model.recompute() }
        .sheet(isPresented: $showAntennas) { AntennaEditorSheet(model: model) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .commaSeparatedText, .plainText, .text, .data]) { result in
            if case let .success(url) = result { Task { await model.importElements(from: url) } }
        }
    }

    // MARK: Header and controls

    private var header: some View {
        HiveInstrumentPanel(status: model.state.summary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HiveStatusBadge("SGP4", tint: HiveInk.cyan)
                    HiveStatusBadge("prediction only", tint: HiveInk.amber)
                }
                Text("Satellite passes")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("When satellites rise over your antenna, how good a chance each pass is with the antennas you have, and where to point. Recording and decoding passes are not built yet.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(model.elementsLine). \(model.transmittersLine). \(TransmitterStore.attribution)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var controls: some View {
        HiveInstrumentPanel(status: model.isRefreshing ? "updating" : nil) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Antenna latitude, longitude", text: $observerText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(applyObserverText)
                    Button("Set location", action: applyObserverText)
                    Button { aviation.requestLocationServices() } label: { Label("Device location", systemImage: "location") }
                }
                HStack(spacing: 10) {
                    Button { Task { await model.refresh(force: true) } } label: {
                        Label("Update elements", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isRefreshing)
                    .help("CelesTrak asks for at most one download every 2 hours; a younger copy is kept.")
                    Button { showImporter = true } label: { Label("Import elements…", systemImage: "square.and.arrow.down") }
                        .help("OMM JSON, OMM CSV or TLE text")
                    Button { showAntennas = true } label: { Label("Antennas…", systemImage: "antenna.radiowaves.left.and.right") }
                    Spacer()
                    Picker("Times", selection: Binding(get: { model.showUTC }, set: { model.showUTC = $0 })) {
                        Text("Local").tag(false)
                        Text("UTC").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .labelsHidden()
                }
                if let observer = model.state.observer {
                    Text("Antenna at \(String(format: "%.4f", observer.latitudeDegrees)), \(String(format: "%.4f", observer.longitudeDegrees))")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                if let error = aviation.locationError { Text(error).font(.caption).foregroundStyle(.red) }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(HiveInk.amber) }
            }
        }
    }

    private var filters: some View {
        @Bindable var model = model
        return HiveInstrumentPanel("Show") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    ForEach(SatelliteCategory.allCases, id: \.self) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { model.state.filters.categories.contains(category) },
                            set: { on in
                                if on { model.state.filters.categories.insert(category) } else { model.state.filters.categories.remove(category) }
                            }))
                        .toggleStyle(.checkbox)
                    }
                    Toggle("Decodable signals only", isOn: $model.state.filters.decodableOnly)
                        .toggleStyle(.checkbox)
                        .help("Hide passes whose downlink SignalHive has no decoder for and will not build one (for example a SARSAT relay).")
                }
                HStack(spacing: 18) {
                    Picker("At least", selection: $model.state.filters.minimumGrade) {
                        Text("Any receivable").tag(PassGrade.poor)
                        Text("Marginal and up").tag(PassGrade.marginal)
                        Text("Good and up").tag(PassGrade.good)
                        Text("Excellent only").tag(PassGrade.excellent)
                        Text("Everything").tag(PassGrade.notReceivable)
                    }
                    .frame(width: 230)
                    HStack {
                        Text("Peak above").fixedSize()
                        Slider(value: $model.state.filters.minimumElevationDegrees, in: 0...70, step: 5).frame(width: 120)
                        Text("\(Int(model.state.filters.minimumElevationDegrees))°").font(.system(.caption, design: .monospaced)).frame(width: 34)
                    }
                    Picker("Window", selection: $model.state.filters.horizonHours) {
                        Text("24 h").tag(24)
                        Text("48 h").tag(48)
                        Text("72 h").tag(72)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
            .font(.callout)
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if case let .offline(reason) = model.state.phase {
            Label("\(reason)", systemImage: "wifi.slash").font(.callout).foregroundStyle(HiveInk.amber)
        }
        if model.usingPresetAntennas {
            Label("Rated as if you have the NooElec kit's three masts (you have not saved your antennas yet). Change them under Antennas.",
                  systemImage: "info.circle").font(.callout).foregroundStyle(.white.opacity(0.7))
        }
        if model.agingCount > 0 {
            Label("\(model.agingCount) satellite\(model.agingCount == 1 ? " has an element set" : "s have element sets") over 3 days old; the times may be off by minutes. Update elements.",
                  systemImage: "clock.badge.exclamationmark").font(.callout).foregroundStyle(HiveInk.amber)
        }
        if !model.problems.isEmpty {
            DisclosureGroup("\(model.problems.count) satellite\(model.problems.count == 1 ? "" : "s") could not be predicted") {
                ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                    Text("\(problem.name): \(problem.message)").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.callout).foregroundStyle(HiveInk.amber)
        }
        if model.deepSpaceSkipped > 0 {
            Text("\(model.deepSpaceSkipped) satellites in high orbits (geostationary weather satellites and similar) have no passes and are not listed.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.state.phase {
        case .needsLocation:
            emptyState("Set your antenna location", "Passes depend on where you are. Type latitude and longitude above, or use your device location.", "location")
        case .loading:
            HStack(spacing: 10) { ProgressView(); Text("Loading elements and transmitters…") }.foregroundStyle(.white.opacity(0.7))
        case .ready, .offline:
            if model.state.all.isEmpty, model.isComputing {
                HStack(spacing: 10) { ProgressView(); Text("Calculating passes…") }.foregroundStyle(.white.opacity(0.7))
            } else if model.state.all.isEmpty {
                emptyState(model.isRefreshing ? "Working…" : "No passes yet",
                           "Update elements to download current orbit data, or import an element file. If you already have, nothing rises above 5° in this window.",
                           "arrow.triangle.2.circlepath")
            } else if model.state.visible().isEmpty {
                emptyState("Your filters hide all \(model.state.all.count) passes",
                           "Lower \"At least\" or the peak elevation, show another category, or untick \"Decodable signals only\". Or add an antenna that covers more downlinks.",
                           "line.3.horizontal.decrease.circle")
            } else {
                passes
            }
        }
    }

    private func emptyState(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HiveInstrumentPanel {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.title3.weight(.semibold))
                Text(detail).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
        }
    }

    private var passes: some View {
        let visible = model.state.visible()
        return VStack(alignment: .leading, spacing: 16) {
            HiveInstrumentPanel("Next \(model.state.filters.horizonHours) hours", status: model.state.summary) {
                // Many satellites make a tall chart: it scrolls inside its panel instead of pushing everything down.
                ScrollView(.vertical) {
                    PassTimelineView(passes: visible, from: model.windowStart,
                                     through: model.windowStart.addingTimeInterval(Double(model.state.filters.horizonHours) * 3600),
                                     observer: model.state.observer, utc: model.showUTC,
                                     selectedID: Binding(get: { model.selectedPassID }, set: { model.selectedPassID = $0 }))
                }
                .frame(maxHeight: 420)
                Text("Bar height is peak elevation, colour is how good a chance it is (grey: not receivable, red: poor, amber: marginal, blue: good, green: excellent). Pale bands are daylight.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            if let selected = model.selected, let observer = model.state.observer {
                HiveInstrumentPanel {
                    PassInspectorView(rated: selected, observer: observer, utc: model.showUTC)
                }
            }
            HiveInstrumentPanel("Passes") {
                LazyVStack(spacing: 6) {
                    ForEach(visible.prefix(80)) { rated in passRow(rated) }
                }
            }
        }
    }

    private func passRow(_ rated: RatedPass) -> some View {
        Button { model.selectedPassID = rated.id } label: {
            HStack(spacing: 12) {
                Circle().fill(PassFormat.gradeColor(rated.rating.grade)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rated.pass.satelliteName).font(.system(.callout, design: .rounded).weight(.semibold)).foregroundStyle(.white)
                    Text("\(PassFormat.day(rated.pass.aos, utc: model.showUTC)) \(PassFormat.time(rated.pass.aos, utc: model.showUTC)) to \(PassFormat.time(rated.pass.los, utc: model.showUTC))"
                         + (rated.transmitter.map { "  \(PassFormat.megahertz($0.downlinkHz)), \(PassFormat.decoderText($0.kind.decoderStatus))" } ?? "  no known downlink"))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text("\(Int(rated.pass.maxElevationDegrees.rounded()))° peak").font(.system(.caption, design: .monospaced)).foregroundStyle(HiveInk.mint)
                HiveStatusBadge(PassFormat.gradeName(rated.rating.grade), tint: PassFormat.gradeColor(rated.rating.grade))
            }
            .padding(10)
            .background(HiveInk.panel.opacity(rated.id == model.selectedPassID ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(rated.id == model.selectedPassID ? HiveInk.cyan : .white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rated.pass.satelliteName), peak \(Int(rated.pass.maxElevationDegrees)) degrees, \(PassFormat.gradeName(rated.rating.grade))")
    }

    // MARK: Location

    private func applyObserverText() {
        if let coordinate = GeoCoordinate.parse(observerText) {
            aviation.setReceiverLocation(coordinate)
        } else {
            model.message = "Type latitude and longitude, like 35.2534, -109.4374."
        }
    }

    private static func text(_ coordinate: GeoCoordinate) -> String {
        String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }
}

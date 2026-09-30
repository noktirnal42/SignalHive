import SwiftUI
import SignalHiveCore

/// The text side of ADS-B and FIS-B: weather reports (METAR, TAF, PIREP, SIGMET ...), notices (NOTAM, TFR), aircraft
/// alerts, and receiver information. The map shows where things are; this shows what was said.
struct AirDataView: View {
    @Environment(AviationModel.self) private var model

    var body: some View {
        ZStack {
            HiveWorkbenchBackground()
            HStack(alignment: .top, spacing: 14) {
                feedColumn
                infoColumn
                    .frame(width: 320)
            }
            .padding(18)
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Air Data")
    }

    // MARK: Feed

    private var feedColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            AirDataFilters(model: model)
            let messages = model.filteredMessages
            if messages.isEmpty {
                AirDataEmpty(model: model, hasAny: !model.picture.messages.messages.isEmpty)
            } else {
                TimelineView(.periodic(from: .now, by: 10)) { timeline in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(messages.prefix(400)) { message in
                                AirMessageCard(message: message, now: timeline.date)
                            }
                            if messages.count > 400 {
                                Text("Showing the newest 400 of \(messages.count).")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.trailing, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Info column

    private var infoColumn: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !model.picture.emergencyAircraft.isEmpty {
                    AirAlertsPanel(aircraft: model.picture.emergencyAircraft)
                }
                AirWeatherBoard(model: model)
                AirReceiverPanel(model: model)
            }
        }
    }
}

// MARK: - Colors

private extension FlightCategory {
    /// The colors charts use for flight categories.
    var tint: Color {
        switch self {
        case .vfr: return Color(red: 0.25, green: 0.85, blue: 0.40)
        case .mvfr: return Color(red: 0.35, green: 0.55, blue: 1.0)
        case .ifr: return Color(red: 1.0, green: 0.30, blue: 0.30)
        case .lifr: return Color(red: 0.95, green: 0.35, blue: 0.95)
        case .unknown: return Color.gray
        }
    }
}

private extension AviationSeverity {
    var tint: Color {
        switch self {
        case .info: return HiveInk.cyan
        case .advisory: return HiveInk.amber
        case .warning: return HiveInk.copper
        case .critical: return Color.red
        }
    }
}

// MARK: - Filters

private struct AirDataFilters: View {
    @Bindable var model: AviationModel

    var body: some View {
        let counts = model.picture.messages.counts()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, station, type", text: $model.messageSearch)
                    .textFieldStyle(.plain)
                Picker("Severity", selection: $model.minimumSeverity) {
                    ForEach(AviationSeverity.allCases, id: \.self) { severity in
                        Text(severity == .info ? "All" : "\(severity.displayName)+").tag(severity)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                Toggle("Latest per station", isOn: $model.latestPerStation)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(10)
            .background(HiveInk.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("All") { model.messageKinds = Set(AviationMessageKind.allCases) }
                        .buttonStyle(.borderless)
                    Button("None") { model.messageKinds = [] }
                        .buttonStyle(.borderless)
                    ForEach(AviationMessageKind.allCases, id: \.self) { kind in
                        chip(kind, count: counts[kind] ?? 0)
                    }
                }
            }
        }
    }

    private func chip(_ kind: AviationMessageKind, count: Int) -> some View {
        let on = model.messageKinds.contains(kind)
        return Button {
            if on { model.messageKinds.remove(kind) } else { model.messageKinds.insert(kind) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: kind.symbolName).font(.caption2)
                Text(kind.displayName).font(.system(size: 11, weight: .semibold, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(count == 0 ? Color.secondary : HiveInk.amber)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(on ? HiveInk.cyan.opacity(0.18) : Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(on ? HiveInk.cyan.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
            .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }
}

private struct AirDataEmpty: View {
    let model: AviationModel
    let hasAny: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hasAny ? "line.3.horizontal.decrease.circle" : "text.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(HiveInk.cyan)
            Text(hasAny ? "Nothing matches these filters" : "No messages yet")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text(hasAny
                 ? "Turn on more kinds, lower the severity, or clear the search."
                 : "Weather reports and notices arrive from 978 MHz FIS-B ground stations; aircraft alerts arrive with ADS-B. Start the demo sky to see samples of every kind.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !hasAny {
                Button {
                    Task { await model.start(.demo) }
                } label: {
                    Label("Start demo sky", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(HiveInk.amber)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Message card

private struct AirMessageCard: View {
    let message: AviationMessage
    let now: Date
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.kind.symbolName)
                .font(.title3)
                .foregroundStyle(message.severity.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(message.title)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    if let category = message.flightCategory, category != .unknown {
                        Text(category.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(category.tint.opacity(0.22), in: Capsule())
                            .overlay(Capsule().stroke(category.tint.opacity(0.7), lineWidth: 1))
                            .foregroundStyle(category.tint)
                    }
                    Spacer(minLength: 6)
                    if message.severity >= .advisory {
                        HiveStatusBadge(message.severity.displayName, tint: message.severity.tint)
                    }
                    Text(AviationFormat.age(now.timeIntervalSince(message.lastSeen)) + " ago")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }

                if let observation = message.observation {
                    observationGrid(observation)
                }

                Text(message.body)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text(message.origin)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    if message.count > 1 {
                        Text("heard \(message.count) times")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    if message.body.count > 160 || message.body.contains("\n") {
                        Button(expanded ? "Less" : "More") { expanded.toggle() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(HiveInk.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle().fill(message.severity.tint).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.07), lineWidth: 1))
    }

    private func observationGrid(_ observation: METARObservation) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
            fact("WIND", observation.windSummary)
            fact("VISIBILITY", observation.visibilitySummary)
            fact("SKY", observation.sky.isEmpty ? nil : observation.skySummary)
            fact("TEMP", observation.temperatureSummary)
            fact("ALTIMETER", observation.altimeterSummary)
            fact("WEATHER", observation.weatherSummary)
            fact("CEILING", observation.ceilingFeet.map { AviationFormat.grouped($0) + " ft" })
            fact("OBSERVED", observation.timeLabel)
        }
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Text(value)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Side panels

private struct AirAlertsPanel: View {
    let aircraft: [AircraftState]

    var body: some View {
        HiveInstrumentPanel("Aircraft alerts", status: "\(aircraft.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(aircraft) { state in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.displayName)
                                .font(.system(.callout, design: .monospaced).weight(.bold))
                                .foregroundStyle(.white)
                            Text(state.squawkAlert?.displayName ?? state.emergency?.label ?? "Emergency")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Text(AviationFormat.altitudeLabel(state.altitudeFeet, onGround: state.onGround))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color(state.color))
                    }
                }
            }
        }
    }
}

/// The latest report for each airport, one line each, colored by flight category.
private struct AirWeatherBoard: View {
    let model: AviationModel

    var body: some View {
        let reports = model.picture.messages.filtered(kinds: [.metar], latestPerStation: true)
            .filter { $0.observation != nil }
            .sorted { ($0.station ?? "") < ($1.station ?? "") }
        HiveInstrumentPanel("Airport weather", status: reports.isEmpty ? "none" : "\(reports.count)") {
            if reports.isEmpty {
                Text("No surface observations heard yet.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                VStack(spacing: 6) {
                    ForEach(reports.prefix(30)) { report in
                        if let observation = report.observation {
                            HStack(spacing: 8) {
                                Circle().fill(observation.flightCategory.tint).frame(width: 9, height: 9)
                                Text(observation.station)
                                    .font(.system(.callout, design: .monospaced).weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 52, alignment: .leading)
                                Text(observation.flightCategory.rawValue)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(observation.flightCategory.tint)
                                    .frame(width: 38, alignment: .leading)
                                Text(summary(observation))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                        }
                    }
                }
            }
        }
    }

    private func summary(_ observation: METARObservation) -> String {
        var parts: [String] = []
        if let speed = observation.windSpeedKnots {
            parts.append(observation.windDirectionDegrees.map { String(format: "%03d/%d", $0, speed) } ?? "VRB/\(speed)")
        }
        if let miles = observation.visibilityMiles { parts.append(String(format: "%gSM", (miles * 100).rounded() / 100)) }
        if let ceiling = observation.ceilingFeet { parts.append("C\(ceiling / 100)") }
        return parts.joined(separator: " ")
    }
}

private struct AirReceiverPanel: View {
    let model: AviationModel

    var body: some View {
        let picture = model.picture
        HiveInstrumentPanel("Receiver", status: model.isRunning ? "on" : "off") {
            VStack(alignment: .leading, spacing: 8) {
                row("Sources", model.activeSources.isEmpty ? "None" : AviationModel.Source.allCases.filter { model.activeSources.contains($0) }.map(\.rawValue).joined(separator: ", "))
                row("Status", model.status)
                row("Aircraft", "\(picture.aircraft.count) (peak \(picture.stats.peakAircraft))")
                row("Messages", AviationFormat.grouped(picture.stats.messages)
                    + (model.isRunning && !model.isDemo ? String(format: "  %.0f/s", model.messageRate) : ""))
                row("Positions", AviationFormat.grouped(picture.stats.positions))
                row("Farthest", picture.receiver == nil ? "set the antenna position" : AviationFormat.distance(picture.stats.farthestNM))
                row("Text reports", "\(picture.stats.textReports)")
                ForEach(AviationModel.Source.allCases.filter { $0.isLive && model.activeSources.contains($0) }) { source in
                    row(source == .adsb1090 ? "1090 frames" : "978 frames", AviationFormat.grouped(model.healths[source]?.frames ?? 0))
                }
                Divider()
                Text("WEATHER RADAR")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                if picture.radar.isEmpty {
                    Text("None received").font(.caption).foregroundStyle(.white.opacity(0.55))
                } else {
                    ForEach(RadarProduct.allCases, id: \.self) { product in
                        if let mosaic = picture.radar[product] {
                            row(product.displayName, "\(mosaic.blockCount) blocks" + (mosaic.latestObservationLabel.map { " \u{00B7} \($0)" } ?? ""))
                        }
                    }
                }
                Divider()
                Text("FIS-B GROUND STATIONS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                if picture.groundStations.isEmpty {
                    Text("None heard").font(.caption).foregroundStyle(.white.opacity(0.55))
                } else {
                    ForEach(picture.groundStations.values.sorted { $0.id < $1.id }) { station in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AviationFormat.coordinate(station.coordinate))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("slot \(station.slotID) \u{00B7} \(station.uplinks) uplinks \u{00B7} heard \(AviationFormat.age(Date().timeIntervalSince(station.lastHeard))) ago")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

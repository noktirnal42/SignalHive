import SwiftUI
import SignalHiveCore

struct DecoderHubView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedPresetID: String?
    @State private var selectedDecoder: DecoderTool = .ais
    @State private var inputText = DecoderTool.ais.sampleInput
    @State private var results: [DecoderWorkbenchMessage] = DecoderWorkbench.decodeAISNMEA(DecoderTool.ais.sampleInput)
    @State private var liveSession = DecoderHubLiveSession()

    var body: some View {
        ZStack {
            HiveWorkbenchBackground()
            HStack(spacing: 0) {
                decoderRail
                    .frame(width: 290)
                Divider().opacity(0.35)
                workbench
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Decoder Hub")
        .task {
            // The Workshop opens a specific decoder by id ("acars", "ais", "morse").
            if case let .decoder(id)? = model.pendingPreset, let tool = DecoderTool(rawValue: id) {
                model.pendingPreset = nil
                selectedDecoder = tool
            }
        }
        .onChange(of: selectedDecoder) { _, decoder in
            liveSession.stop(clearOutputs: true)
            inputText = decoder.sampleInput
            decode()
            selectedPresetID = nil
            if model.liveDecoder.isActive, model.liveDecoder.preset?.kind.rawValue != decoder.rawValue {
                Task { await model.liveDecoder.stop() }
            }
        }
        .onDisappear {
            // A decoder nobody can see should not keep the only dongle.
            if model.liveDecoder.isActive { Task { await model.liveDecoder.stop() } }
        }
    }

    // MARK: Live session

    private var liveKind: LiveDecoderKind? { LiveDecoderKind(rawValue: selectedDecoder.rawValue) }

    private var livePresets: [DecoderLivePreset] {
        liveKind.map(DecoderLivePreset.presets(for:)) ?? []
    }

    private var selectedPreset: DecoderLivePreset? {
        livePresets.first { $0.id == selectedPresetID } ?? livePresets.first
    }

    @ViewBuilder
    private var livePanel: some View {
        if let kind = liveKind, let preset = selectedPreset {
            let live = model.liveDecoder
            HiveInstrumentPanel("Live from the dongle", status: liveStatusText(live)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Picker("Channel", selection: Binding(get: { preset.id }, set: { selectedPresetID = $0 })) {
                            ForEach(livePresets) { item in
                                Text("\(item.name) · \(String(format: "%.3f", item.frequencyMHz)) MHz").tag(item.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        .disabled(live.isActive)

                        HStack(spacing: 6) {
                            Text("Gain").font(.caption).foregroundStyle(.white.opacity(0.6))
                            Slider(value: Bindable(live).gainDB, in: 0...50, step: 1)
                                .frame(width: 130)
                                .disabled(live.isActive)
                            Text("\(Int(live.gainDB)) dB").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.7))
                        }

                        Spacer(minLength: 0)

                        if live.isActive {
                            Button {
                                Task { await live.stop() }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(HiveInk.copper)
                        } else {
                            Button {
                                Task { await live.start(preset) }
                            } label: {
                                Label("Start listening", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(HiveInk.cyan)
                        }
                    }

                    if let failure = live.failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(HiveInk.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let snapshot = live.snapshot, live.isActive || snapshot.totalBlocks > 0 {
                        HStack(spacing: 18) {
                            liveStat("Source", live.deviceName ?? "stopped")
                            liveStat("Blocks", "\(snapshot.totalBlocks)")
                            liveStat("Messages", "\(snapshot.totalMessageCount)")
                            liveStat("Per minute", String(format: "%.1f", snapshot.messagesPerMinute))
                            liveStat("Last heard", snapshot.lastHeardAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "nothing yet")
                        }
                    }

                    Text(kind.caveat)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func liveStatusText(_ live: LiveDecoderModel) -> String {
        switch live.state {
        case .idle: return "stopped"
        case .starting: return "starting"
        case .running: return "listening"
        case .failed: return "could not start"
        }
    }

    private func liveStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var liveResultsPanel: some View {
        let live = model.liveDecoder
        if liveKind != nil, live.preset?.kind.rawValue == selectedDecoder.rawValue, live.isActive || !live.rows.isEmpty {
            HiveInstrumentPanel("Heard on the air", status: "\(live.rows.count) messages") {
                VStack(alignment: .leading, spacing: 12) {
                    if live.rows.isEmpty {
                        Text("Listening. Nothing decoded yet; this is normal until a signal on this channel is strong and clean enough.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Spacer()
                            Button("Clear") { live.clear() }
                                .buttonStyle(.bordered)
                        }
                        ForEach(live.rows) { message in
                            messageCard(message)
                        }
                    }
                }
            }
        }
    }

    private var decoderRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Decoder Hub")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text("Live decoding from the dongle for ACARS, AIS and Morse, a demo signal for trying them without one, and manual decode tools.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(DecoderTool.allCases) { decoder in
                    Button {
                        selectedDecoder = decoder
                    } label: {
                        decoderRow(decoder)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(decoder.title) decoder")
                }

                HiveInstrumentPanel("Live sessions", status: "ACARS, AIS, Morse") {
                    VStack(alignment: .leading, spacing: 10) {
                        decoderStatus("Morse / CW", state: "Dongle (not yet checked on air) + demo", tint: HiveInk.amber)
                        decoderStatus("ACARS", state: "Dongle (not yet checked on air) + demo", tint: HiveInk.amber)
                        decoderStatus("AIS", state: "Dongle (not yet checked on air)", tint: HiveInk.amber)
                        decoderStatus("ADS-B / UAT", state: "Live in Air Map", tint: HiveInk.mint)
                        decoderStatus("ISM sensors", state: "SwiftRTLSDR ready", tint: HiveInk.amber)
                        decoderStatus("RS41 radiosondes", state: "SwiftRTLSDR ready", tint: HiveInk.amber)
                        decoderStatus("Meteor LRPT", state: "SatDump-grade UI pending", tint: HiveInk.amber)
                        decoderStatus("Paging / weak signal", state: "Adapter path only", tint: .secondary)
                    }
                }
            }
            .padding(18)
        }
        .background(HiveInk.graphite.opacity(0.82))
    }

    private func decoderRow(_ decoder: DecoderTool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: decoder.symbol)
                .foregroundStyle(selectedDecoder == decoder ? HiveInk.cyan : .white.opacity(0.58))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(decoder.title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.94))
                Text(decoder.status)
                    .font(.caption)
                    .foregroundStyle(decoder.tint)
                Text(decoder.summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedDecoder == decoder ? HiveInk.cyan.opacity(0.14) : Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedDecoder == decoder ? HiveInk.cyan.opacity(0.45) : .white.opacity(0.07), lineWidth: 1)
        }
    }

    private func decoderStatus(_ title: String, state: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
            Spacer(minLength: 0)
            Text(state)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.52))
        }
    }

    private var workbench: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                livePanel
                liveResultsPanel
                // The demo signal only where there is one; a decoder with a dongle panel and no demo does not need a "not wired" box.
                if selectedDecoder.supportsDemoSession || liveKind == nil { liveSessionPanel }
                inputPanel
                resultsPanel
            }
            .padding(24)
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }

    private var liveSessionPanel: some View {
        HiveInstrumentPanel(selectedDecoder.supportsDemoSession ? "Demo signal (no dongle)" : "Live session", status: liveSession.statusBadge(for: selectedDecoder)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(liveSession.title(for: selectedDecoder))
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(liveSession.subtitle(for: selectedDecoder))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    liveSessionControl
                }

                if let snapshot = liveSession.snapshot {
                    sessionStats(snapshot)
                }

                if let error = liveSession.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(HiveInk.amber)
                }

                if !liveSession.messages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Session Messages")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.62))
                        ForEach(liveSession.messages) { message in
                            messageCard(message)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var liveSessionControl: some View {
        if selectedDecoder.supportsDemoSession {
            Button {
                if liveSession.isRunning {
                    liveSession.stop()
                } else {
                    liveSession.start(decoder: selectedDecoder, inputText: inputText)
                }
            } label: {
                Label(liveSession.buttonTitle, systemImage: liveSession.buttonSymbol)
            }
            .buttonStyle(.borderedProminent)
            .tint(liveSession.isRunning ? HiveInk.amber : HiveInk.cyan)
            .accessibilityLabel(liveSession.isRunning ? "Stop decoder session" : "Start decoder demo session")
        } else {
            Label("No hub session yet", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.46))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
                .accessibilityLabel("No Decoder Hub live session is available for \(selectedDecoder.title)")
        }
    }

    private func sessionStats(_ snapshot: DecoderSessionSnapshot) -> some View {
        HStack(spacing: 8) {
            statPill("State", snapshot.state.rawValue)
            statPill("Blocks", "\(snapshot.totalBlocks)")
            statPill("Samples", snapshot.totalSamples.formatted())
            statPill("Messages", "\(snapshot.totalMessageCount)")
            statPill("Rate", String(format: "%.1f/min", snapshot.messagesPerMinute))
        }
    }

    private func statPill(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }

    private var hero: some View {
        HiveInstrumentPanel(status: selectedDecoder.status.lowercased()) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        HiveStatusBadge(selectedDecoder.badge, tint: selectedDecoder.tint)
                        HiveStatusBadge("Swift", tint: HiveInk.cyan)
                    }
                    Text(selectedDecoder.title)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(selectedDecoder.longDescription)
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    Image(systemName: selectedDecoder.symbol)
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(selectedDecoder.tint)
                    Text(selectedDecoder.frequencyHint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
        }
    }

    private var inputPanel: some View {
        HiveInstrumentPanel("Input", status: selectedDecoder.inputLabel) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $inputText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.white)
                    .frame(minHeight: 148)
                    .padding(8)
                    .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }

                HStack(spacing: 10) {
                    Button {
                        decode()
                    } label: {
                        Label("Decode", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HiveInk.cyan)

                    Button {
                        inputText = selectedDecoder.sampleInput
                        decode()
                    } label: {
                        Label("Sample", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .tint(HiveInk.amber)

                    if selectedDecoder == .morse {
                        Button {
                            inputText = DecoderWorkbench.encodeMorseText(inputText)
                            decode()
                        } label: {
                            Label("Encode text", systemImage: "textformat.abc")
                        }
                        .buttonStyle(.bordered)
                        .tint(HiveInk.mint)
                    }

                    Spacer()
                    Text(selectedDecoder.inputHelp)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.52))
                }
            }
        }
    }

    private var resultsPanel: some View {
        HiveInstrumentPanel("Messages", status: "\(results.filter { $0.status == .decoded }.count) decoded") {
            VStack(alignment: .leading, spacing: 12) {
                if results.isEmpty {
                    emptyState
                } else {
                    ForEach(results) { message in
                        messageCard(message)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.forward")
                .font(.system(size: 36))
                .foregroundStyle(HiveInk.cyan.opacity(0.72))
            Text("No messages yet")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.82))
            Text("Paste input and press Decode.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func messageCard(_ message: DecoderWorkbenchMessage) -> some View {
        let tint = message.status == .decoded ? HiveInk.mint : HiveInk.amber
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(message.decoder)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(tint)
                Text(message.title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(message.status == .decoded ? "decoded" : "check input")
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            Text(message.summary)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .textSelection(.enabled)
            if !message.details.isEmpty {
                HStack {
                    ForEach(message.details, id: \.self) { detail in
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
            Text(message.raw)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(HiveInk.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
    }

    private func decode() {
        switch selectedDecoder {
        case .ais:
            results = DecoderWorkbench.decodeAISNMEA(inputText)
        case .morse:
            results = [DecoderWorkbench.decodeMorsePatterns(inputText)]
        case .acars:
            results = DecoderWorkbench.decodeACARSText(inputText)
        case .adsb, .uat, .ism, .radiosonde, .lrpt, .paging, .weakSignal:
            results = [
                DecoderWorkbenchMessage(
                    decoder: selectedDecoder.title,
                    title: "Live session not wired yet",
                    summary: selectedDecoder.pendingSummary,
                    details: [selectedDecoder.frequencyHint, selectedDecoder.status],
                    raw: inputText,
                    status: .rejected
                )
            ]
        }
    }
}

private enum DecoderTool: String, CaseIterable, Identifiable {
    case ais
    case morse
    case acars
    case adsb
    case uat
    case ism
    case radiosonde
    case lrpt
    case paging
    case weakSignal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ais: return "AIS NMEA"
        case .morse: return "Morse / CW"
        case .acars: return "ACARS text"
        case .adsb: return "ADS-B 1090"
        case .uat: return "UAT / FIS-B 978"
        case .ism: return "ISM sensors"
        case .radiosonde: return "RS41 radiosonde"
        case .lrpt: return "Meteor LRPT"
        case .paging: return "POCSAG / FLEX"
        case .weakSignal: return "FT8 / WSPR"
        }
    }

    var symbol: String {
        switch self {
        case .ais: return "ferry"
        case .morse: return "dot.circle"
        case .acars: return "teletype"
        case .adsb: return "airplane"
        case .uat: return "cloud.sun.rain"
        case .ism: return "sensor"
        case .radiosonde: return "balloon"
        case .lrpt: return "globe.europe.africa"
        case .paging: return "message.badge.waveform"
        case .weakSignal: return "sparkles"
        }
    }

    var status: String {
        switch self {
        case .ais, .morse, .acars: return "Live + manual"
        case .adsb, .uat: return "Live elsewhere"
        case .ism, .radiosonde, .lrpt: return "Driver ready"
        case .paging, .weakSignal: return "Adapter pending"
        }
    }

    var badge: String {
        switch self {
        case .ais, .morse, .acars: return "live"
        case .adsb, .uat: return "air"
        case .ism, .radiosonde, .lrpt: return "driver"
        case .paging, .weakSignal: return "adapter"
        }
    }

    var tint: Color {
        switch self {
        case .ais, .morse, .acars: return HiveInk.mint
        case .adsb, .uat: return HiveInk.cyan
        case .ism, .radiosonde, .lrpt: return HiveInk.amber
        case .paging, .weakSignal: return .secondary
        }
    }

    var summary: String {
        switch self {
        case .ais: return "Paste !AIVDM or !AIVDO sentences."
        case .morse: return "Decode dot/dash groups or encode text."
        case .acars: return "Summarize decoded VHF aircraft text."
        case .adsb: return "Use Air Map for live aircraft."
        case .uat: return "Use Air Data for weather products."
        case .ism: return "SwiftRTLSDR decoder awaits capture UI."
        case .radiosonde: return "RS41 frames await tracking UI."
        case .lrpt: return "LRPT awaits capture and image products."
        case .paging: return "External adapter is not attached."
        case .weakSignal: return "Text parser has no audio path."
        }
    }

    var longDescription: String {
        switch self {
        case .ais:
            return "Decode marine AIS NMEA sentences into MMSI, position, speed, course and static vessel fields."
        case .morse:
            return "Decode pasted dot/dash groups, or encode plain text into Morse patterns for CW practice and decoder checks."
        case .acars:
            return "Summarize decoded ACARS text by label, flight, registration and likely message kind while the SDR frame session is being built."
        case .adsb:
            return "The live 1090 MHz receiver is already wired into Air Map and Air Data; this hub links the decoder family together."
        case .uat:
            return "The live 978 MHz receiver is already wired into Air Map and Air Data for UAT traffic, FIS-B weather and text products."
        case .ism:
            return "SwiftRTLSDR contains rtl_433-style protocol decoders. SignalHive still needs the live capture session and message table."
        case .radiosonde:
            return "SwiftRTLSDR contains Vaisala RS41 frame decoding. SignalHive still needs scan, track and map tools."
        case .lrpt:
            return "SwiftRTLSDR contains Meteor LRPT demodulation and product parsing. SignalHive still needs pass-to-capture, Doppler assist and an image browser."
        case .paging:
            return "Paging currently depends on adapter output. The planned work is an original Swift path and a live message view."
        case .weakSignal:
            return "Weak-signal text parsers exist, but SignalHive still needs an audio/IQ feed and timing recovery."
        }
    }

    var frequencyHint: String {
        switch self {
        case .ais: return "161.975 / 162.025 MHz"
        case .morse: return "CW narrowband"
        case .acars: return "VHF ACARS channels"
        case .adsb: return "1090 MHz"
        case .uat: return "978 MHz"
        case .ism: return "433.92 MHz and peers"
        case .radiosonde: return "400-406 MHz"
        case .lrpt: return "137 MHz weather sats"
        case .paging: return "VHF / UHF paging"
        case .weakSignal: return "audio passband"
        }
    }

    var inputLabel: String {
        switch self {
        case .ais: return "NMEA"
        case .morse: return "patterns or text"
        case .acars: return "text frames"
        default: return "live source"
        }
    }

    var inputHelp: String {
        switch self {
        case .ais: return "One NMEA sentence per line"
        case .morse: return "Use / between words; demo IQ replays decoded text through DecoderSession"
        case .acars: return "One decoded message per line; demo IQ wraps it as a clean ACARS frame"
        default: return "Live RTL-SDR session wiring comes next"
        }
    }

    var sampleInput: String {
        switch self {
        case .ais:
            return "!AIVDM,1,1,,A,15M:Ih001sG@0Q8K;P8:V`MD0000,0*75"
        case .morse:
            return "... --- ... / -.-. --.- / - . ... -"
        case .acars:
            return "Q0 N123AB DAL123 POS 37.62 -122.38"
        default:
            return pendingSummary
        }
    }

    var supportsDemoSession: Bool {
        switch self {
        case .morse, .acars: return true
        default: return false
        }
    }

    var demoFrequencyHz: Double {
        switch self {
        case .morse: return 7_030_000
        case .acars: return 131_550_000
        default: return 0
        }
    }

    func makeDecoder() -> (any SignalDecoder)? {
        switch self {
        case .morse: return MorseDecoder()
        case .acars: return ACARSDecoder()
        default: return nil
        }
    }

    func demoIQ(from input: String, sampleRate: Double) -> [ComplexFloat] {
        switch self {
        case .morse:
            let message = DecoderWorkbench.decodeMorsePatterns(input)
            let text = message.status == .decoded ? message.summary : input
            let firstWord = text
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .first ?? "TEST"
            return DecoderDemoSignal.morseIQ(text: firstWord, sampleRate: sampleRate, wordsPerMinute: 22)
        case .acars:
            let text = input
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? sampleInput
            return DecoderDemoSignal.acarsIQ(text: text, sampleRate: sampleRate)
        default:
            return []
        }
    }

    var pendingSummary: String {
        switch self {
        case .adsb:
            return "Start 1090 MHz ADS-B from Air Map. DecoderSession is now in core; this hub still needs shared live tables."
        case .uat:
            return "Start 978 MHz UAT/FIS-B from Air Data or Air Map. DecoderSession is now in core; this hub still needs shared live tables."
        case .ism:
            return "SwiftRTLSDR has the ISM decoder family and SignalHive now has DecoderSession; source selection, gain, protocol filters and export are next."
        case .radiosonde:
            return "SwiftRTLSDR has RS41 decoding and SignalHive now has DecoderSession; scan presets, map tracks and launch-site summaries are next."
        case .lrpt:
            return "SwiftRTLSDR has Meteor LRPT pieces and SignalHive now has DecoderSession; pass handoff, Doppler assist, capture and image gallery are next."
        case .paging:
            return "SignalHive currently parses adapter output only. Original Swift paging demodulation remains planned."
        case .weakSignal:
            return "Weak-signal message parsing exists, but there is no live audio/IQ timing path into it yet."
        default:
            return sampleInput
        }
    }
}

@MainActor
@Observable
private final class DecoderHubLiveSession {
    var isRunning = false
    var statusText = "Idle"
    var snapshot: DecoderSessionSnapshot?
    var messages: [DecoderWorkbenchMessage] = []
    var lastError: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var currentSession: DecoderSession?

    var buttonTitle: String {
        if isRunning { return "Stop" }
        if statusText == "Demo complete" { return "Replay demo IQ" }
        return "Start demo IQ"
    }

    var buttonSymbol: String {
        isRunning ? "stop.fill" : "dot.radiowaves.forward"
    }

    func title(for decoder: DecoderTool) -> String {
        decoder.supportsDemoSession ? "Synthetic IQ through DecoderSession" : "No demo signal for this decoder"
    }

    func subtitle(for decoder: DecoderTool) -> String {
        switch decoder {
        case .morse:
            return "Generates clean CW IQ from the text input, feeds it into MorseDecoder through DecoderSession, and reports live stats."
        case .acars:
            return "Wraps the first ACARS text line as a clean frame, generates FM/MSK-like IQ, and decodes it through DecoderSession."
        case .adsb:
            return "1090 MHz ADS-B already runs from Air Map and Air Data; shared hub tables are still pending."
        case .uat:
            return "978 MHz UAT/FIS-B already runs from Air Map and Air Data; shared hub tables are still pending."
        default:
            return "Core or driver pieces exist, but source selection, gain, capture presets and over-the-air QA are still required."
        }
    }

    func statusBadge(for decoder: DecoderTool) -> String {
        if isRunning { return "running" }
        if !decoder.supportsDemoSession { return "not wired" }
        return statusText.lowercased()
    }

    func start(decoder tool: DecoderTool, inputText: String) {
        stop()
        guard tool.supportsDemoSession, let signalDecoder = tool.makeDecoder() else {
            statusText = "Not wired"
            lastError = "This decoder does not have an app-owned live session control yet."
            return
        }

        let sampleRate = 48_000.0
        let iq = tool.demoIQ(from: inputText, sampleRate: sampleRate)
        guard !iq.isEmpty else {
            statusText = "No signal"
            lastError = "No demo IQ could be generated for this decoder."
            return
        }

        let session = DecoderSession(
            decoder: signalDecoder,
            config: DecoderSessionConfig(
                centerFrequencyHz: tool.demoFrequencyHz,
                sampleRateHz: sampleRate,
                gainDB: 0,
                channelBandwidthHz: signalDecoder.requiredBandwidth,
                maxRetainedMessages: 50
            )
        )
        currentSession = session
        isRunning = true
        statusText = "Running"
        lastError = nil
        messages.removeAll(keepingCapacity: true)
        snapshot = nil

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await session.start()
                self.snapshot = await session.snapshot
                for start in stride(from: 0, to: iq.count, by: tool.demoChunkSize) {
                    if Task.isCancelled { break }
                    let end = min(iq.count, start + tool.demoChunkSize)
                    let decoded = await session.ingest(samples: Array(iq[start..<end]))
                    if !decoded.isEmpty {
                        self.prepend(messages: decoded.map(Self.message(from:)))
                    }
                    self.snapshot = await session.snapshot
                    try await Task.sleep(for: .milliseconds(70))
                }
                await session.stop()
                self.snapshot = await session.snapshot
                if !Task.isCancelled {
                    self.isRunning = false
                    self.statusText = self.messages.isEmpty ? "No messages" : "Demo complete"
                }
            } catch is CancellationError {
                await session.stop()
                self.snapshot = await session.snapshot
                self.isRunning = false
                self.statusText = "Stopped"
            } catch {
                await session.stop()
                self.snapshot = await session.snapshot
                self.isRunning = false
                self.statusText = "Failed"
                self.lastError = error.localizedDescription
            }
        }
    }

    func stop(clearOutputs: Bool = false) {
        task?.cancel()
        task = nil
        let session = currentSession
        currentSession = nil
        if isRunning {
            statusText = "Stopped"
        }
        isRunning = false
        if let session {
            Task { await session.stop() }
        }
        if clearOutputs {
            statusText = "Idle"
            snapshot = nil
            messages.removeAll(keepingCapacity: true)
            lastError = nil
        }
    }

    private func prepend(messages newMessages: [DecoderWorkbenchMessage]) {
        messages.insert(contentsOf: newMessages, at: 0)
        if messages.count > 12 {
            messages.removeLast(messages.count - 12)
        }
    }

    private static func message(from decoded: DecodedMessage) -> DecoderWorkbenchMessage {
        switch decoded.payload {
        case .morse(let morse):
            return DecoderWorkbenchMessage(
                decoder: "Morse",
                title: "CW message",
                summary: morse.text,
                details: [
                    String(format: "%.0f WPM", morse.wordsPerMinute),
                    String(format: "%.0f%% confidence", morse.confidence * 100)
                ],
                raw: "DecoderSession \(decoded.mode)",
                status: .decoded
            )
        case .acars(let acars):
            var details = ["Label \(acars.label)", acars.kind.displayName]
            if let registration = acars.registration { details.append("Registration \(registration)") }
            if let flight = acars.flightId { details.append("Flight \(flight)") }
            return DecoderWorkbenchMessage(
                decoder: "ACARS",
                title: acars.flightId ?? acars.registration ?? "ACARS frame",
                summary: acars.text,
                details: details,
                raw: "DecoderSession \(decoded.mode)",
                status: .decoded
            )
        case .text(let text):
            return DecoderWorkbenchMessage(
                decoder: decoded.mode,
                title: "Text",
                summary: text,
                raw: text,
                status: .decoded
            )
        default:
            return DecoderWorkbenchMessage(
                decoder: decoded.mode,
                title: "Decoded message",
                summary: "Payload \(String(describing: decoded.payload))",
                raw: "DecoderSession \(decoded.mode)",
                status: .decoded
            )
        }
    }
}

private extension DecoderTool {
    var demoChunkSize: Int {
        switch self {
        case .acars: return 1_024
        case .morse: return 4_096
        default: return 2_048
        }
    }
}

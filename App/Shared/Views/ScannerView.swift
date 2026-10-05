import SwiftUI
import SignalHiveCore

struct ScannerView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var manager = SDRDeviceManager.shared

    @State private var pipeline: DSPPipeline?
    @State private var running = false
    @State private var frequencyMHz = 155.475
    @State private var gain: Double = 30
    @State private var squelchDB: Float = -80
    @State private var mode: DemodMode = .nfm
    @State private var latest = LatestSpectrum()
    @State private var displaySpectrum: [Float] = []
    @State private var waterfall = WaterfallBuffer(width: 2048, height: 400)
    @State private var waterfallImage: CGImage?
    @State private var scale = SpectrumScale(minDB: -100, maxDB: -40)
    @State private var rowThrottle = FrameThrottle(minimumInterval: 1.0 / 25)
    @State private var drawThrottle = FrameThrottle(minimumInterval: 1.0 / 30)
    @State private var activityThrottle = FrameThrottle(minimumInterval: 0.8)
    @State private var fftSize = 4096
    @State private var frequencyText = ""
    @State private var stepKHz: Double = 12.5
    @State private var rssiDB: Float = -140
    @State private var statusMessage: String?
    @State private var found: [FoundFrequency] = []
    @State private var showFinder = false
    @State private var rtlTCPHost = ""
    @State private var showingRTLTCPField = false
    @State private var liveScan = true
    @State private var activityLog = ScanActivityLog()
    @State private var selectedActivityID: Int?
    @State private var heldActivityID: Int?
    @State private var lockedOutKeys: Set<Int> = []
    @State private var rfCoachRequest: RFCoachRequest?

    @AppStorage("scannerVolumeLevel") private var volumeLevel = 0.6
    @AppStorage("scannerMuted") private var muted = false

    private let displayBins = 1024
    private let sampleRateHz = 2_048_000.0
    private static let stepsKHz: [Double] = [5, 6.25, 12.5, 25, 100, 1000]

    private var selectedActivity: ScanActivity? {
        guard let selectedActivityID else { return activityLog.hits.first { !$0.lockedOut } }
        return activityLog.hits.first { $0.id == selectedActivityID }
    }

    var body: some View {
        ZStack {
            HiveWorkbenchBackground()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    frequencyHeader
                    Divider().overlay(.white.opacity(0.08))
                    spectrumDisplay
                    waterfallDisplay
                    Divider().overlay(.white.opacity(0.08))
                    controls
                }
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(.white.opacity(0.10))

                scannerRail
                    .frame(width: 350)
            }
        }
        .navigationTitle("Scanner")
        .task {
            await manager.scan()
            if let pending = model.pendingScanFrequency {
                frequencyMHz = pending / 1_000_000
                model.pendingScanFrequency = nil
                if running { await retune() }
            }
            if model.pendingAddNetworkSource {
                model.pendingAddNetworkSource = false
                showingRTLTCPField = true
            }
            if case let .scannerTune(mhz, tuneMode)? = model.pendingPreset {
                model.pendingPreset = nil
                await listen(mhz: mhz, mode: tuneMode)
            }
        }
        .onChange(of: model.pendingScanFrequency) { _, pending in
            guard let pending else { return }
            frequencyMHz = pending / 1_000_000
            model.pendingScanFrequency = nil
            Task { await retune() }
        }
        .sheet(isPresented: $showFinder) { finderSheet }
        .sheet(item: $rfCoachRequest) { request in
            RFCoachSheet(request: request)
        }
    }

    private var frequencyHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HiveStatusBadge(running ? "receiving" : "standby", tint: running ? HiveInk.mint : HiveInk.amber)
                    HiveStatusBadge(liveScan ? "live scan" : "monitor", tint: liveScan ? HiveInk.cyan : .secondary)
                    if heldActivityID != nil { HiveStatusBadge("hold", tint: HiveInk.copper) }
                }
                HStack(spacing: 10) {
                    Button { step(-1) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(HiveInk.cyan)
                        .help("Tune down one step")
                    TextField("MHz", text: $frequencyText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 42, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 300)
                        .onSubmit { commitFrequencyText() }
                    Text("MHz")
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    Button { step(1) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(HiveInk.cyan)
                        .help("Tune up one step")
                    Picker("Step", selection: $stepKHz) {
                        ForEach(Self.stepsKHz, id: \.self) { khz in
                            Text(khz >= 1000 ? "\(Int(khz / 1000)) MHz" : "\(khz.formatted()) kHz").tag(khz)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 104)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Text(statusMessage ?? (running ? "Receiving from \(activeSourceName)" : "Select a source and start"))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                HStack(spacing: 10) {
                    metricBadge("RSSI", value: "\(Int(rssiDB)) dBFS", hot: rssiDB > squelchDB)
                    metricBadge("Mode", value: mode.rawValue, hot: true)
                    metricBadge("Hits", value: "\(activityLog.hits.filter { !$0.lockedOut }.count)", hot: !activityLog.hits.isEmpty)
                }
            }
        }
        .padding(18)
        .background {
            LinearGradient(
                colors: [HiveInk.panelTop.opacity(0.95), HiveInk.panel.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .onAppear { frequencyText = Self.format(frequencyMHz) }
        .onChange(of: frequencyMHz) { _, value in frequencyText = Self.format(value) }
    }

    private func metricBadge(_ label: String, value: String, hot: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.44))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(hot ? HiveInk.mint : .white.opacity(0.62))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var activeSourceName: String {
        manager.activeDevices.first?.name ?? "source"
    }

    private var volume: AudioVolume { AudioVolume(level: Float(volumeLevel), isMuted: muted) }

    private var volumeIcon: String {
        if muted || volumeLevel == 0 { return "speaker.slash.fill" }
        if volumeLevel < 0.34 { return "speaker.wave.1.fill" }
        return volumeLevel < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private static func format(_ mhz: Double) -> String { String(format: "%.5f", mhz) }

    private func commitFrequencyText() {
        guard let value = FrequencyEntry.parseMHz(frequencyText) else {
            frequencyText = Self.format(frequencyMHz)
            return
        }
        setFrequency(mhz: value)
    }

    private func step(_ direction: Double) {
        setFrequency(mhz: frequencyMHz + direction * stepKHz / 1_000)
    }

    private func setFrequency(mhz: Double) {
        frequencyMHz = max(0.1, mhz)
        frequencyText = Self.format(frequencyMHz)
        waterfall = WaterfallBuffer(width: waterfall.width, height: waterfall.height)
        waterfallImage = nil
        if pipeline != nil { Task { await retune() } }
    }

    private var spectrumDisplay: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard displaySpectrum.count > 1 else { return }
                let n = displaySpectrum.count
                let step = size.width / CGFloat(n - 1)
                var line = Path()
                for (i, value) in displaySpectrum.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step,
                                        y: size.height - CGFloat(scale.normalized(value)) * size.height)
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [HiveInk.cyan.opacity(0.58), HiveInk.blue.opacity(0.08)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(line, with: .color(HiveInk.cyan.opacity(0.92)), lineWidth: 1)

                for activity in activityLog.hits.prefix(12) where !activity.lockedOut {
                    let fraction = (activity.frequencyHz / 1_000_000 - frequencyMHz) / (sampleRateHz / 1_000_000) + 0.5
                    guard fraction >= 0, fraction <= 1 else { continue }
                    let x = CGFloat(fraction) * size.width
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(marker, with: .color(HiveInk.amber.opacity(0.42)), lineWidth: 1)
                }

                var centre = Path()
                centre.move(to: CGPoint(x: size.width / 2, y: 0))
                centre.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                context.stroke(centre, with: .color(.white.opacity(0.30)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            .overlay(alignment: .bottom) {
                HStack {
                    Text(edgeLabel(-0.5))
                    Spacer()
                    Text(edgeLabel(0))
                    Spacer()
                    Text(edgeLabel(0.5))
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.58))
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                let fraction = Double(tap.location.x / max(1, geometry.size.width)) - 0.5
                let clicked = frequencyMHz + fraction * sampleRateHz / 1_000_000
                setFrequency(mhz: FrequencyEntry.snap(mhz: clicked, stepKHz: stepKHz))
            })
        }
        .frame(height: 128)
        .background(Color.black.opacity(0.88))
        .help("Click to tune")
    }

    private func edgeLabel(_ fraction: Double) -> String {
        String(format: "%.3f", frequencyMHz + fraction * sampleRateHz / 1_000_000)
    }

    private var waterfallDisplay: some View {
        Group {
            if let image = waterfallImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.black.overlay {
                    Text("Start a source to paint the waterfall")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.34))
                }
            }
        }
        .frame(maxHeight: .infinity)
        .frame(minHeight: 240)
        .background(Color.black)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { Task { await toggleStream() } } label: {
                    Label(running ? "Stop" : "Start", systemImage: running ? "stop.circle.fill" : "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(running ? .red : .green)

                Toggle(isOn: $liveScan) {
                    Label("Live Scan", systemImage: "waveform.path.ecg.rectangle")
                }
                .toggleStyle(.switch)

                Button { holdSelected() } label: {
                    Label(heldActivityID == nil ? "Hold" : "Release", systemImage: heldActivityID == nil ? "pause.circle" : "play.circle")
                }
                .disabled(selectedActivity == nil)

                Button { skipSelected() } label: {
                    Label("Skip", systemImage: "forward.end")
                }
                .disabled(selectedActivity == nil)

                Button { toggleLockoutSelected() } label: {
                    Label(selectedActivity?.lockedOut == true ? "Unlock" : "Lockout", systemImage: selectedActivity?.lockedOut == true ? "lock.open" : "lock")
                }
                .disabled(selectedActivity == nil)

                Button { saveSelectedToCodeplug() } label: {
                    Label("Save", systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(selectedActivity == nil)

                Spacer(minLength: 0)
            }

            HStack(spacing: 18) {
                sliderBlock("Gain", value: $gain, range: 0...49, suffix: "dB") {
                    Task { await applyControls() }
                }
                sliderBlock("Squelch", value: Binding(
                    get: { Double(squelchDB) },
                    set: { squelchDB = Float($0) }
                ), range: -120...(-30), suffix: "dB") {
                    Task { await applyControls() }
                }

                HStack(spacing: 7) {
                    Button { muted.toggle() } label: {
                        Image(systemName: volumeIcon)
                            .frame(width: 22)
                            .foregroundStyle(muted ? Color.secondary : Color.white.opacity(0.88))
                    }
                    .buttonStyle(.borderless)
                    Slider(value: $volumeLevel, in: 0...1)
                        .frame(width: 110)
                }
                .onChange(of: volumeLevel) { _, _ in Task { await pipeline?.setVolume(volume) } }
                .onChange(of: muted) { _, _ in Task { await pipeline?.setVolume(volume) } }

                Picker("Mode", selection: $mode) {
                    ForEach(DemodMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .frame(width: 112)
                .onChange(of: mode) { _, _ in Task { await applyControls() } }

                Picker("Detail", selection: $fftSize) {
                    ForEach([2048, 4096, 8192, 16384], id: \.self) { size in
                        Text("\(Int(sampleRateHz) / size) Hz").tag(size)
                    }
                }
                .frame(width: 132)
                .onChange(of: fftSize) { _, _ in Task { await applyControls() } }

                Button { Task { await retune() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .help("Retune")

                Button { findActive() } label: {
                    Label("Find", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(displaySpectrum.isEmpty)
            }
        }
        .padding(14)
        .background(HiveInk.panel.opacity(0.92))
    }

    private func sliderBlock(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, onEditingEnded: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) \(Int(value.wrappedValue)) \(suffix)")
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.62))
            Slider(value: value, in: range) { editing in
                if !editing { onEditingEnded() }
            }
        }
        .frame(minWidth: 150, maxWidth: 240)
    }

    private var scannerRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                activityPanel
                scanBankPanel
                sourcePanel
                decoderPanel
            }
            .padding(14)
        }
        .background(HiveInk.graphite.opacity(0.78))
    }

    private var activityPanel: some View {
        HiveInstrumentPanel("Activity", status: "\(activityLog.hits.count) hits") {
            if activityLog.hits.isEmpty {
                emptyRailState("No activity yet", icon: "waveform.badge.magnifyingglass")
            } else {
                VStack(spacing: 8) {
                    ForEach(activityLog.hits.prefix(12)) { activity in
                        activityRow(activity)
                    }
                }
            }
        }
    }

    private func activityRow(_ activity: ScanActivity) -> some View {
        let selected = selectedActivity?.id == activity.id
        return Button {
            selectedActivityID = activity.id
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: activity.lockedOut ? "lock.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(activity.lockedOut ? HiveInk.copper : HiveInk.mint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.displayMHz)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(activity.lockedOut ? 0.45 : 0.94))
                    HStack(spacing: 8) {
                        Text("\(Int(activity.strengthDB)) dB")
                        if let snr = activity.snrDB { Text("SNR \(Int(snr))") }
                        Text("x\(activity.hitCount)")
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
                Button { tune(activity) } label: { Image(systemName: "scope") }
                    .buttonStyle(.borderless)
                    .help("Tune")
                Button { explain(activity) } label: { Image(systemName: "sparkles") }
                    .buttonStyle(.borderless)
                    .help("Explain with RF Coach")
                Button { save(activity) } label: { Image(systemName: "rectangle.stack.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("Save to codeplug")
            }
            .padding(8)
            .background(selected ? HiveInk.cyan.opacity(0.16) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? HiveInk.cyan.opacity(0.42) : .white.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var scanBankPanel: some View {
        HiveInstrumentPanel("Scan Bank", status: ScanList.starterPublicSafety.name) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ScanList.starterPublicSafety.channels.prefix(7)) { channel in
                    HStack(spacing: 8) {
                        Image(systemName: channel.mode.icon)
                            .foregroundStyle(HiveInk.amber)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(channel.name)
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white.opacity(0.84))
                            Text(channel.displayMHz)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white.opacity(0.44))
                        }
                        Spacer(minLength: 0)
                        Button { setFrequency(mhz: channel.frequencyHz / 1_000_000); mode = channel.mode } label: {
                            Image(systemName: "scope")
                        }
                        .buttonStyle(.borderless)
                        Button { model.addToCodeplug(channel: channel.codeplugChannel()) } label: {
                            Image(systemName: "rectangle.stack.badge.plus")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var sourcePanel: some View {
        HiveInstrumentPanel("Sources", status: manager.isScanning ? "refreshing" : "\(manager.availableDevices.count)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { Task { await manager.scan() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(manager.isScanning)
                    Spacer()
                    if RTLSDRAvailability.current.isAvailable {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(HiveInk.mint)
                            .help(RTLSDRAvailability.current.summary)
                    }
                }

                ForEach(manager.availableDevices, id: \.id) { device in
                    sourceRow(device)
                }

                if !RTLSDRAvailability.current.isAvailable {
                    Label {
                        Text(RTLSDRAvailability.current.summary)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.56))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HiveInk.amber)
                    }
                }

                Divider().overlay(.white.opacity(0.08))

                if showingRTLTCPField {
                    HStack {
                        TextField("rtl_tcp host", text: $rtlTCPHost)
                            .textFieldStyle(.roundedBorder)
                        Button { addRTLTCP() } label: { Image(systemName: "plus") }
                            .disabled(rtlTCPHost.isEmpty)
                    }
                } else {
                    Button { showingRTLTCPField = true } label: {
                        Label("Add rtl_tcp source", systemImage: "network")
                    }
                }
            }
        }
    }

    private func sourceRow(_ device: any SDRDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: device.deviceType.icon)
                .foregroundStyle(HiveInk.cyan)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                Text(device.frequencyRange.description)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if manager.activeDevices.contains(where: { $0.id == device.id }) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HiveInk.mint)
            } else {
                Button { Task { await useDevice(device) } } label: {
                    Text("Use")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    private var decoderPanel: some View {
        HiveInstrumentPanel("Decoder Queue", status: "next") {
            VStack(alignment: .leading, spacing: 8) {
                decoderChip("ADS-B", detail: "Tune 1090 MHz", frequencyMHz: 1090, mode: .raw, icon: "airplane")
                decoderChip("UAT", detail: "Tune 978 MHz", frequencyMHz: 978, mode: .raw, icon: "cloud.sun.rain")
                decoderChip("ACARS", detail: "VHF aviation text", frequencyMHz: 131.55, mode: .am, icon: "teletype")
                decoderChip("AIS", detail: "Marine data", frequencyMHz: 162.025, mode: .nfm, icon: "ferry")
            }
        }
    }

    private func decoderChip(_ title: String, detail: String, frequencyMHz: Double, mode chipMode: DemodMode, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(HiveInk.violet)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.84))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.44))
            }
            Spacer(minLength: 0)
            Button { setFrequency(mhz: frequencyMHz); mode = chipMode } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.borderless)
        }
    }

    private func emptyRailState(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.32))
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.50))
        }
        .frame(maxWidth: .infinity, minHeight: 76)
    }

    private var finderSheet: some View {
        NavigationStack {
            List {
                if found.isEmpty {
                    Text("No active signals above threshold")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(found) { peak in
                        HStack {
                            Text(peak.displayMHz)
                                .font(.body.monospaced())
                            Spacer()
                            if let snr = peak.snrDB {
                                Text(String(format: "SNR %.0f", snr))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(String(format: "%.0f dB", peak.strengthDB))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Tune") {
                                setFrequency(mhz: peak.frequencyHz / 1_000_000)
                                showFinder = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Add") {
                                save(ScanActivity(frequencyHz: peak.frequencyHz, strengthDB: peak.strengthDB,
                                                  noiseFloorDB: peak.noiseFloorDB, bandwidthHz: peak.bandwidthHz))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .navigationTitle("Frequency Finder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showFinder = false }
                }
                ToolbarItem {
                    Button("Refresh") { findActive() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func ingest(spectrum averaged: [Float]) {
        latest.bins = averaged
        let now = Date.timeIntervalSinceReferenceDate
        if liveScan, activityThrottle.shouldEmit(at: now) {
            updateActivity(from: averaged)
        }
        guard drawThrottle.shouldEmit(at: now) else { return }
        displaySpectrum = SpectrumResampler.maxPool(averaged, to: displayBins)
        if let peak = averaged.max() { rssiDB = peak }
        scale = scale.blended(toward: .auto(for: displaySpectrum), alpha: 0.12)
        if rowThrottle.shouldEmit(at: now) {
            waterfall.push(row: averaged, scale: scale)
            waterfallImage = Self.makeImage(waterfall)
        }
    }

    private func updateActivity(from averaged: [Float]) {
        let peaks = FrequencyFinder.find(
            magnitudes: averaged,
            centerFrequencyHz: frequencyMHz * 1_000_000,
            sampleRateHz: sampleRateHz,
            thresholdDB: max(-95, squelchDB),
            minimumSNRDB: 8
        )
        guard !peaks.isEmpty else { return }
        activityLog.ingest(peaks, lockedOutKeys: lockedOutKeys)
        if selectedActivityID == nil {
            selectedActivityID = activityLog.hits.first { !$0.lockedOut }?.id
        }
    }

    private static func makeImage(_ buffer: WaterfallBuffer) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(buffer.pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: buffer.width, height: buffer.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: buffer.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The Workshop's "Start listening": tune, then start on the first real receiver (never the test generator).
    private func listen(mhz: Double, mode tuneMode: DemodMode) async {
        mode = tuneMode
        frequencyMHz = max(0.1, mhz)
        frequencyText = Self.format(frequencyMHz)
        guard let device = manager.availableDevices.first(where: { !($0 is TestSignalDevice) }) else {
            statusMessage = "No receiver found. Plug in an RTL-SDR or add a network source."
            return
        }
        await useDevice(device)
    }

    private func useDevice(_ device: any SDRDevice) async {
        do {
            try await manager.activate(device)
            guard let pl = manager.pipeline(for: device) else {
                statusMessage = "No pipeline for device"
                return
            }
            var config = await pl.currentConfig
            config.frequency = frequencyMHz * 1_000_000
            config.gain = gain
            config.squelchDBFS = squelchDB
            config.mode = mode
            config.fftConfig.fftSize = fftSize
            try await pl.configure(config)
            await pl.setVolume(volume)

            await pl.subscribeToFFT { averaged, _ in
                Task { @MainActor in ingest(spectrum: averaged) }
            }
            await pl.subscribeToIQ { _ in }

            pipeline = pl
            try await pl.start()
            running = true
            statusMessage = device.name
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }

    private func toggleStream() async {
        guard let pipeline else {
            statusMessage = "Select a source first"
            return
        }
        if running {
            await pipeline.stop()
            running = false
            statusMessage = "Stopped"
        } else {
            do {
                try await pipeline.start()
                running = true
                statusMessage = "Receiving"
            } catch {
                running = false
                statusMessage = "Start failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyControls() async {
        guard let pipeline else { return }
        var config = await pipeline.currentConfig
        config.gain = gain
        config.squelchDBFS = squelchDB
        config.mode = mode
        config.fftConfig.fftSize = fftSize
        do {
            try await pipeline.configure(config)
            statusMessage = "\(mode.rawValue) \(String(format: "%.0f", gain)) dB"
        } catch {
            statusMessage = "Configure failed: \(error.localizedDescription)"
        }
    }

    private func retune() async {
        guard let pipeline else {
            statusMessage = "Select a source first"
            return
        }
        var config = await pipeline.currentConfig
        config.frequency = frequencyMHz * 1_000_000
        do {
            try await pipeline.configure(config)
            statusMessage = String(format: "Tuned %.5f MHz", frequencyMHz)
        } catch {
            statusMessage = "Tune failed: \(error.localizedDescription)"
        }
    }

    private func findActive() {
        found = FrequencyFinder.find(
            magnitudes: latest.bins,
            centerFrequencyHz: frequencyMHz * 1_000_000,
            sampleRateHz: sampleRateHz,
            thresholdDB: max(-95, squelchDB),
            minimumSNRDB: 8
        )
        activityLog.ingest(found, lockedOutKeys: lockedOutKeys)
        showFinder = true
    }

    private func tune(_ activity: ScanActivity) {
        selectedActivityID = activity.id
        setFrequency(mhz: activity.frequencyHz / 1_000_000)
    }

    private func explain(_ activity: ScanActivity) {
        selectedActivityID = activity.id
        rfCoachRequest = RFCoachRequest(
            title: activity.displayMHz,
            subtitle: "Live scanner hit · \(mode.rawValue) · \(Int(activity.strengthDB)) dBFS",
            context: SignalDescriptionContext(
                frequencyHz: activity.frequencyHz,
                mode: ChannelMode(demodMode: mode),
                bandwidthHz: activity.bandwidthHz ?? mode.defaultBandwidth,
                rssiDBFS: Double(activity.strengthDB),
                serviceName: activity.label.isEmpty ? nil : activity.label,
                modeHints: modeHints(for: mode)
            ),
            operatorNote: activity.snrDB.map { String(format: "Estimated SNR %.0f dB from the current noise floor.", $0) }
        )
    }

    private func modeHints(for mode: DemodMode) -> [ModeHint] {
        switch mode {
        case .am:
            return [.am]
        case .nfm, .wfm:
            return [.analogFM]
        case .usb, .lsb:
            return [.ssb]
        case .cw, .raw:
            return [.unknown]
        }
    }

    private func holdSelected() {
        if heldActivityID != nil {
            heldActivityID = nil
            statusMessage = "Scan hold released"
            return
        }
        guard let selectedActivity else { return }
        heldActivityID = selectedActivity.id
        tune(selectedActivity)
        statusMessage = "Holding \(selectedActivity.displayMHz)"
    }

    private func skipSelected() {
        guard let selectedActivity else { return }
        let current = selectedActivity.id
        selectedActivityID = activityLog.hits.first { !$0.lockedOut && $0.id != current }?.id
        statusMessage = "Skipped \(selectedActivity.displayMHz)"
    }

    private func toggleLockoutSelected() {
        guard let selectedActivity else { return }
        let key = ScanActivity.key(for: selectedActivity.frequencyHz)
        if lockedOutKeys.contains(key) {
            lockedOutKeys.remove(key)
            activityLog.setLockedOut(frequencyHz: selectedActivity.frequencyHz, lockedOut: false)
            statusMessage = "Unlocked \(selectedActivity.displayMHz)"
        } else {
            lockedOutKeys.insert(key)
            activityLog.setLockedOut(frequencyHz: selectedActivity.frequencyHz, lockedOut: true)
            if heldActivityID == selectedActivity.id { heldActivityID = nil }
            statusMessage = "Locked out \(selectedActivity.displayMHz)"
        }
    }

    private func saveSelectedToCodeplug() {
        guard let selectedActivity else { return }
        save(selectedActivity)
    }

    private func save(_ activity: ScanActivity) {
        let channel = ScanChannel(
            name: activity.label.isEmpty ? "Live \(activity.displayMHz)" : activity.label,
            frequencyHz: activity.frequencyHz,
            bandwidthHz: activity.bandwidthHz ?? mode.defaultBandwidth,
            mode: mode,
            source: .liveHit,
            notes: activity.snrDB.map { String(format: "Scanner hit: %.0f dB SNR, %.0f dBFS", $0, activity.strengthDB) } ?? "Scanner hit"
        )
        model.addToCodeplug(channel: channel.codeplugChannel())
        statusMessage = "Saved \(activity.displayMHz) to codeplug"
    }

    private func addRTLTCP() {
        let host = rtlTCPHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        manager.addNetworkDevice(host: host, port: 1234)
        rtlTCPHost = ""
        showingRTLTCPField = false
        Task { await manager.scan() }
    }
}

final class LatestSpectrum {
    var bins: [Float] = []
}

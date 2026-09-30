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
    @State private var latest = LatestSpectrum()           // full resolution, for the finder (no redraw on write)
    @State private var displaySpectrum: [Float] = []       // reduced for drawing
    @State private var waterfall = WaterfallBuffer(width: 2048, height: 400)
    @State private var waterfallImage: CGImage?
    @State private var scale = SpectrumScale(minDB: -100, maxDB: -40)
    @State private var rowThrottle = FrameThrottle(minimumInterval: 1.0 / 25)
    @State private var drawThrottle = FrameThrottle(minimumInterval: 1.0 / 30)
    @State private var fftSize = 4096
    @AppStorage("scannerVolumeLevel") private var volumeLevel = 0.6
    @AppStorage("scannerMuted") private var muted = false
    @State private var frequencyText = ""
    @State private var stepKHz: Double = 12.5
    @State private var rssiDB: Float = -140
    @State private var statusMessage: String?
    @State private var found: [FoundFrequency] = []
    @State private var showFinder = false
    @State private var rtlTCPHost = ""
    @State private var showingRTLTCPField = false

    private let displayBins = 1024
    private let sampleRateHz = 2_048_000.0

    private static let stepsKHz: [Double] = [5, 6.25, 12.5, 25, 100, 1000]

    var body: some View {
        VStack(spacing: 0) {
            frequencyHeader
            Divider()
            spectrumDisplay
            waterfallDisplay
            Divider()
            controls
            deviceSection
        }
        .navigationTitle("Scanner")
        .task {
            await manager.scan()
            if let pending = model.pendingScanFrequency {
                frequencyMHz = pending / 1_000_000
                model.pendingScanFrequency = nil
                if running {
                    await retune()
                }
            }
        }
        .onChange(of: model.pendingScanFrequency) { _, pending in
            guard let pending else { return }
            frequencyMHz = pending / 1_000_000
            model.pendingScanFrequency = nil
            Task { await retune() }
        }
        .sheet(isPresented: $showFinder) { finderSheet }
    }

    // MARK: Header

    private var frequencyHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button { step(-1) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Tune down one step")
                TextField("MHz", text: $frequencyText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: 260)
                    .onSubmit { commitFrequencyText() }
                Text("MHz").font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Button { step(1) } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .help("Tune up one step")
                Picker("Step", selection: $stepKHz) {
                    ForEach(Self.stepsKHz, id: \.self) { khz in
                        Text(khz >= 1000 ? "\(Int(khz / 1000)) MHz" : "\(khz.formatted()) kHz").tag(khz)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
            }
            HStack(spacing: 12) {
                Text("RSSI \(String(format: "%.0f", rssiDB)) dBFS")
                    .font(.caption.monospaced())
                    .foregroundStyle(rssiDB > squelchDB ? Color.green : Color.secondary)
                Text(mode.rawValue)
                    .font(.caption)
                Spacer()
                Text(statusMessage ?? (running ? "Receiving" : "Idle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { frequencyText = Self.format(frequencyMHz) }
        .onChange(of: frequencyMHz) { _, value in frequencyText = Self.format(value) }
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

    // MARK: Spectrum

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
                    Gradient(colors: [Color.cyan.opacity(0.55), Color.blue.opacity(0.10)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(Color.cyan.opacity(0.95)), lineWidth: 1)
                // Centre marker
                var centre = Path()
                centre.move(to: CGPoint(x: size.width / 2, y: 0))
                centre.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                context.stroke(centre, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
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
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                let fraction = Double(tap.location.x / max(1, geometry.size.width)) - 0.5
                let clicked = frequencyMHz + fraction * sampleRateHz / 1_000_000
                setFrequency(mhz: FrequencyEntry.snap(mhz: clicked, stepKHz: stepKHz))
            })
        }
        .frame(height: 120)
        .background(Color.black.opacity(0.85))
        .help("Click to tune")
    }

    /// Frequency label at a fraction of the band (-0.5 = left edge, 0 = centre, 0.5 = right edge).
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
                Color.black
            }
        }
        .frame(height: 200)
        .background(Color.black)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                Task { await toggleStream() }
            } label: {
                Label(running ? "Stop" : "Start", systemImage: running ? "stop.circle.fill" : "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(running ? .red : .green)

            VStack(alignment: .leading) {
                Text("Gain \(Int(gain)) dB").font(.caption)
                Slider(value: $gain, in: 0...49) { _ in Task { await applyControls() } }
            }
            VStack(alignment: .leading) {
                Text("Squelch \(Int(squelchDB)) dB").font(.caption)
                Slider(value: $squelchDB, in: -120...(-30)) { _ in Task { await applyControls() } }
            }

            HStack(spacing: 6) {
                Button { muted.toggle() } label: {
                    Image(systemName: volumeIcon)
                        .frame(width: 22)
                        .foregroundStyle(muted ? Color.secondary : Color.primary)
                }
                .buttonStyle(.borderless)
                .help(muted ? "Unmute" : "Mute")
                Slider(value: $volumeLevel, in: 0...1)
                    .frame(width: 100)
                    .help("Volume")
            }
            .onChange(of: volumeLevel) { _, _ in Task { await pipeline?.setVolume(volume) } }
            .onChange(of: muted) { _, _ in Task { await pipeline?.setVolume(volume) } }

            Picker("Mode", selection: $mode) {
                ForEach(DemodMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .frame(maxWidth: 110)
            .onChange(of: mode) { _, _ in Task { await applyControls() } }

            Picker("Detail", selection: $fftSize) {
                ForEach([2048, 4096, 8192, 16384], id: \.self) { size in
                    Text("\(Int(sampleRateHz) / size) Hz").tag(size)
                }
            }
            .frame(width: 130)
            .help("Frequency detail: the width of each spectrum bin. Finer detail shows narrower signals.")
            .onChange(of: fftSize) { _, _ in Task { await applyControls() } }

            Button {
                Task { await retune() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Retune")

            Button {
                findActive()
            } label: {
                Label("Find", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(displaySpectrum.isEmpty)
            .help("Find active frequencies in the live spectrum")
        }
        .padding()
    }

    // MARK: Device section

    private var deviceSection: some View {
        Section {
            HStack {
                Text("Source")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await manager.scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(manager.isScanning)
            }
            .padding([.top, .horizontal])

            ForEach(manager.availableDevices, id: \.id) { device in
                HStack {
                    Label(device.name, systemImage: device.deviceType.icon)
                    Spacer()
                    if manager.activeDevices.contains(where: { $0.id == device.id }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Use") {
                            Task { await useDevice(device) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
            }

            if !RTLSDRLibrary.status.isAvailable {
                Label {
                    Text(RTLSDRLibrary.status.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(5)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(.horizontal)
            }

            if showingRTLTCPField {
                HStack {
                    TextField("rtl_tcp host (e.g. 192.168.1.50)", text: $rtlTCPHost)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        addRTLTCP()
                    }
                    .disabled(rtlTCPHost.isEmpty)
                }
                .padding(.horizontal)
            } else {
                Button {
                    showingRTLTCPField = true
                } label: {
                    Label("Add rtl_tcp source…", systemImage: "network")
                }
                .padding(.horizontal)
            }
            Spacer(minLength: 8)
        }
    }

    // MARK: Finder sheet

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
                            Text(String(format: "%.0f dB", peak.strengthDB))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Add") {
                                model.addToCodeplug(channel: CodeplugChannel(
                                    name: String(format: "%.3f", peak.frequencyHz / 1_000_000),
                                    frequencyHz: peak.frequencyHz
                                ))
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

    // MARK: Spectrum intake

    /// Called for every FFT frame (~125 a second). Only redraws about 30 times a second and adds a waterfall
    /// row about 25 times a second, so the UI stays light and the waterfall scrolls at a readable speed.
    private func ingest(spectrum averaged: [Float]) {
        latest.bins = averaged
        let now = Date.timeIntervalSinceReferenceDate
        guard drawThrottle.shouldEmit(at: now) else { return }
        displaySpectrum = SpectrumResampler.maxPool(averaged, to: displayBins)
        if let peak = averaged.max() { rssiDB = peak }
        scale = scale.blended(toward: .auto(for: displaySpectrum), alpha: 0.12)
        if rowThrottle.shouldEmit(at: now) {
            waterfall.push(row: averaged, scale: scale)
            waterfallImage = Self.makeImage(waterfall)
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

    // MARK: Actions

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
            sampleRateHz: sampleRateHz
        )
        showFinder = true
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

/// Holds the newest full-resolution spectrum for the Frequency Finder. A class, so updating it every frame does
/// not make SwiftUI redraw the view.
final class LatestSpectrum {
    var bins: [Float] = []
}

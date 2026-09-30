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
    @State private var spectrum: [Float] = []
    @State private var waterfall: [[Float]] = []
    @State private var rssiDB: Float = -140
    @State private var statusMessage: String?
    @State private var found: [FoundFrequency] = []
    @State private var showFinder = false
    @State private var rtlTCPHost = ""
    @State private var showingRTLTCPField = false

    private let waterfallRows = 120
    private let waterfallBins = 256

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
            Text(String(format: "%.5f MHz", frequencyMHz))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
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
    }

    // MARK: Spectrum

    private var spectrumDisplay: some View {
        Canvas { context, size in
            guard !spectrum.isEmpty else { return }
            let n = spectrum.count
            let barWidth = size.width / CGFloat(n)
            let minDB: Float = -120
            let maxDB: Float = 0
            for (i, value) in spectrum.enumerated() {
                let clamped = min(max(value, minDB), maxDB)
                let h = CGFloat((clamped - minDB) / (maxDB - minDB)) * size.height
                let rect = CGRect(
                    x: CGFloat(i) * barWidth,
                    y: size.height - h,
                    width: max(1, barWidth),
                    height: h
                )
                let color: Color = value > squelchDB ? .green : .blue
                context.fill(Path(rect), with: .color(color.opacity(0.85)))
            }
        }
        .frame(height: 120)
        .background(Color.black.opacity(0.85))
    }

    private var waterfallDisplay: some View {
        Canvas { context, size in
            guard !waterfall.isEmpty else { return }
            let rowHeight = size.height / CGFloat(waterfallRows)
            for (rowIndex, row) in waterfall.enumerated() {
                guard !row.isEmpty else { continue }
                let bins = row.count
                let cellWidth = size.width / CGFloat(bins)
                let y = CGFloat(rowIndex) * rowHeight
                for (i, value) in row.enumerated() {
                    let t = min(max((value + 110) / 70, 0), 1) // -110..-40 dBFS
                    let color = waterColor(Float(t))
                    let rect = CGRect(x: CGFloat(i) * cellWidth, y: y, width: max(0.5, cellWidth), height: max(0.5, rowHeight))
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(height: 180)
        .background(Color.black)
    }

    private func waterColor(_ t: Float) -> Color {
        let v = CGFloat(t)
        switch v {
        case ..<0.2: return Color(hue: 0.66, saturation: 1, brightness: v * 2)
        case ..<0.45: return Color(hue: 0.55, saturation: 1, brightness: 0.4 + v)
        case ..<0.7: return Color(hue: 0.28, saturation: 1, brightness: 0.5 + v * 0.5)
        default: return Color(hue: 0.0, saturation: 1, brightness: 0.6 + v * 0.4)
        }
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

            Picker("Mode", selection: $mode) {
                ForEach(DemodMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .frame(maxWidth: 110)
            .onChange(of: mode) { _, _ in Task { await applyControls() } }

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
            .disabled(spectrum.isEmpty)
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
            try await pl.configure(config)

            await pl.subscribeToFFT { averaged, _ in
                Task { @MainActor in
                    spectrum = averaged
                    if let peak = averaged.max() { rssiDB = peak }
                }
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
            magnitudes: spectrum,
            centerFrequencyHz: frequencyMHz * 1_000_000,
            sampleRateHz: 2_048_000
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

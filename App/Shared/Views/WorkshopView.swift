import SwiftUI
import SignalHiveCore

struct WorkshopView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var manager = SDRDeviceManager.shared

    var openPanel: (ContentView.Panel) -> Void

    private var installedPackCount: Int {
        model.states.filter {
            if case .installed = $0.status { return true }
            return false
        }.count
    }

    var body: some View {
        ZStack {
            HiveWorkbenchBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    statusStrip
                    actionGrid
                    ForEach(WorkshopSection.allCases, id: \.self) { section in
                        capabilitySection(section.title, items: WorkshopCatalog.items(in: section, for: environment))
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180, alignment: .leading)
            }
        }
        .navigationTitle("Workshop")
        .task { await manager.scan() }
    }

    private var hero: some View {
        HiveInstrumentPanel(status: AppConfiguration.usesMockData ? "demo data" : "live bench") {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        HiveStatusBadge("FCC")
                        HiveStatusBadge("SDR", tint: HiveInk.amber)
                        HiveStatusBadge("DSP", tint: HiveInk.mint)
                    }
                    Text("SignalHive")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("A native RF workbench for licensing data, live capture, decoding, trunking, and codeplug work.")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                    HiveSpectrumRibbon(samples: heroSamples, tint: HiveInk.cyan)
                        .frame(height: 78)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HiveSignalMeter(
                    value: min(1, Double(installedPackCount + manager.availableDevices.count) / 6.0),
                    label: "BENCH",
                    unit: "\(installedPackCount) / \(manager.availableDevices.count)",
                    tint: HiveInk.amber
                )
                .frame(width: 260, height: 180)
            }
        }
    }

    private var statusStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            metric("Data Packs", value: "\(installedPackCount)", icon: "externaldrive.fill", tint: HiveInk.amber)
            metric("Sources", value: "\(manager.availableDevices.count)", icon: "antenna.radiowaves.left.and.right", tint: HiveInk.cyan)
            metric("Demods", value: "\(DemodMode.allCases.count)", icon: "waveform", tint: HiveInk.mint)
            metric("Decoders", value: "\(WorkshopCatalog.workingDecoders(for: environment))", icon: "dot.radiowaves.forward", tint: HiveInk.violet)
        }
    }

    private func metric(_ title: String, value: String, icon: String, tint: Color) -> some View {
        HiveInstrumentPanel(status: title) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 88)
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
            action("Browse FCC", icon: "list.bullet.indent", panel: .browse)
            action("AI Lab", icon: "brain.head.profile", panel: .aiLab)
            action("Search", icon: "magnifyingglass", panel: .search)
            action("Trunked", icon: "antenna.radiowaves.left.and.right", panel: .trunked)
            action("Scanner", icon: "waveform.path.ecg", panel: .scanner)
            action("Satellites", icon: "globe.americas", panel: .satellites)
            action("Codeplug", icon: "memorychip", panel: .codeplug)
            action("Air Map", icon: "airplane", panel: .airMap)
            action("Air Data", icon: "doc.text.magnifyingglass", panel: .airData)
        }
    }

    private func action(_ title: String, icon: String, panel: ContentView.Panel) -> some View {
        Button {
            openPanel(panel)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.bordered)
        .tint(HiveInk.cyan)
    }

    private func capabilitySection(_ title: String, items: [WorkshopItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    capabilityTile(item)
                }
            }
        }
    }

    private func capabilityTile(_ item: WorkshopItem) -> some View {
        let color = Self.color(for: item.status)
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .foregroundStyle(color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(2)
                    Text(item.status.label)
                        .font(.caption)
                        .foregroundStyle(color)
                }
                Spacer(minLength: 0)
                if item.destination != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)
            if let setup = item.setup {
                Label(setup, systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(HiveInk.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HiveSpectrumRibbon(samples: Self.samples(for: item.id), tint: color)
                .frame(height: 28)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
        .background(HiveInk.panel.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }

        return Group {
            if let destination = item.destination {
                Button { openPanel(Self.panel(for: destination)) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    /// What this machine has, from what the app can see.
    private var environment: WorkshopEnvironment {
        var dongles = 0
        if case let .found(list) = RTLSDRAvailability.current.state { dongles = list.count }
        var tools: Set<String> = []
        #if os(macOS)
        for tool in ["dsdccx", "multimon-ng"] where DecoderToolExecutableLocator.live.resolveExecutableURL(
            basenames: [tool], candidatePaths: ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]) != nil {
            tools.insert(tool)
        }
        #endif
        return WorkshopEnvironment(
            installedPacks: installedPackCount,
            rtlsdrDongles: dongles,
            rtlsdrSummary: RTLSDRAvailability.current.summary,
            hackRFPresent: manager.availableDevices.contains { $0 is HackRFDevice },
            networkSources: manager.availableDevices.filter { $0 is NetworkSDRDevice || $0 is OpenWebRXDevice }.count,
            tools: tools,
            codeplugChannels: model.codeplug.channels.count,
            demodModes: DemodMode.allCases.filter { $0 != .raw }.map(\.rawValue),
            aiModelsInstalled: model.models.installedCount,
            usesDemoData: AppConfiguration.usesMockData)
    }

    private static func panel(for destination: WorkshopDestination) -> ContentView.Panel {
        switch destination {
        case .browse: return .browse
        case .search: return .search
        case .scanner: return .scanner
        case .trunked: return .trunked
        case .codeplug: return .codeplug
        case .aiLab: return .aiLab
        case .satellites: return .satellites
        case .airMap: return .airMap
        case .airData: return .airData
        }
    }

    private static func color(for status: WorkshopStatus) -> Color {
        switch status {
        case .ready: return .green
        case .needsSetup: return .orange
        case .notConnected: return .yellow.opacity(0.8)
        case .planned: return .secondary
        }
    }

    /// The little ribbon on each tile: decoration, but the same every launch (`hashValue` is different every run).
    private static func samples(for id: String) -> [Double] {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let seed = Double(hash % 17) / 30.0
        return [
            0.12 + seed, 0.18, 0.22 + seed / 2, 0.15, 0.34,
            0.20, 0.68 - seed / 2, 0.24, 0.17, 0.42 + seed,
            0.23, 0.19, 0.78 - seed / 3, 0.28, 0.16
        ].map { min(0.95, max(0.08, $0)) }
    }

    private var heroSamples: [Double] {
        [0.16, 0.20, 0.18, 0.24, 0.42, 0.23, 0.19, 0.31, 0.82, 0.27, 0.21, 0.34, 0.53, 0.29, 0.24, 0.91, 0.46, 0.28, 0.22, 0.38, 0.74, 0.33, 0.26, 0.20]
    }
}

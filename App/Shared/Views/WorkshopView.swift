import SwiftUI
import SignalHiveCore

struct WorkshopView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var manager = SDRDeviceManager.shared

    /// Open and launch actions go to `ContentView`; fixes and explanations are the sheets below.
    var perform: (WorkshopAction) -> Void
    @State private var sheet: WorkshopSheet?
    @State private var showRoadmap = false

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
                    quickActions
                    ForEach(WorkshopSection.allCases, id: \.self) { section in
                        let items = WorkshopCatalog.homeItems(for: environment).filter { $0.section == section }
                        if !items.isEmpty { capabilitySection(section.title, items: items) }
                    }
                    roadmap
                }
                .padding(24)
                .frame(maxWidth: 1180, alignment: .leading)
            }
        }
        .navigationTitle("Workshop")
        .task { await manager.scan() }
        .sheet(item: $sheet) { sheet in sheetContent(sheet) }
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Capabilities that work on this machine now, of the ones that are written.
                let readiness = WorkshopCatalog.readiness(for: environment)
                HiveSignalMeter(
                    value: readiness.implemented == 0 ? 0 : Double(readiness.ready) / Double(readiness.implemented),
                    label: "READY",
                    unit: "\(readiness.ready) / \(readiness.implemented)",
                    tint: HiveInk.amber
                )
                .frame(width: 260, height: 180)
            }
        }
    }

    private var statusStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            metric("Data Packs", value: "\(installedPackCount)", icon: "externaldrive.fill", tint: HiveInk.amber)
            metric("Sources", value: "\(realSources.count)", icon: "antenna.radiowaves.left.and.right", tint: HiveInk.cyan)
            metric("Demods", value: "\(DemodMode.allCases.filter { $0 != .raw }.count)", icon: "waveform", tint: HiveInk.mint)
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

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick actions")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(WorkshopCatalog.quickActions(for: environment)) { quick in
                    quickActionButton(quick)
                }
            }
        }
    }

    private func quickActionButton(_ quick: WorkshopQuickAction) -> some View {
        let tint = quick.needsSetup ? HiveInk.amber : HiveInk.cyan
        return Button {
            handle(quick.action, title: quick.title)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: quick.symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(quick.title)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text(quick.needsSetup ? "Needs setup · \(quick.action.label)" : quick.detail)
                        .font(.caption)
                        .foregroundStyle(quick.needsSetup ? HiveInk.amber : .white.opacity(0.56))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(HiveInk.panel.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.28), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(quick.needsSetup ? "\(quick.title). Needs setup: \(quick.action.label)" : quick.title)
    }

    private var roadmap: some View {
        let items = WorkshopCatalog.roadmapItems(for: environment)
        return DisclosureGroup(isExpanded: $showRoadmap) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white.opacity(0.8))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Roadmap: \(items.count) things not built yet")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
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
        return VStack(alignment: .leading, spacing: 10) {
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
            Spacer(minLength: 0)
            if let action = item.action, let label = item.actionLabel {
                Button {
                    handle(action, title: item.title)
                } label: {
                    Text(label).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(color)
                .accessibilityLabel("\(label): \(item.title)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .background(HiveInk.panel.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }
    }

    private func handle(_ action: WorkshopAction, title: String) {
        switch action {
        case .open, .launch:
            perform(action)
        case .fix(.getFCCData):
            sheet = .getData
        case .fix(.addNetworkSource):
            model.pendingAddNetworkSource = true
            perform(.open(.scanner))
        case .fix(.usbHelp):
            sheet = .usbHelp
        case let .fix(.installTool(name)):
            sheet = .install(name)
        case let .learn(text):
            sheet = .learn(title: title, text: text)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WorkshopSheet) -> some View {
        switch sheet {
        case .getData:
            GetDataSheet()
        case .usbHelp:
            WorkshopInfoSheet.usbHelp(
                checkAgain: { Task { await manager.scan() } },
                addNetworkSource: { handle(.fix(.addNetworkSource), title: "") })
        case let .install(name):
            WorkshopInfoSheet.install(name) { Task { await manager.scan() } }
        case let .learn(title, text):
            WorkshopInfoSheet(title: title, message: text)
        }
    }

    /// Receivers that can deliver samples: the built-in test generator is not one.
    private var realSources: [any SDRDevice] {
        manager.availableDevices.filter { !($0 is TestSignalDevice) }
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

    private static func color(for status: WorkshopStatus) -> Color {
        switch status {
        case .ready: return .green
        case .needsSetup: return .orange
        case .notConnected: return .yellow.opacity(0.8)
        case .planned: return .secondary
        }
    }
}

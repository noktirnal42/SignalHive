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
                    capabilitySection("RF Workflows", items: rfCapabilities)
                    capabilitySection("Protocol Decoders", items: decoderCapabilities)
                    capabilitySection("Hardware & Field Integrations", items: hardwareCapabilities)
                    capabilitySection("Planned Lab Areas", items: plannedCapabilities)
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
            metric("Decoders", value: "8", icon: "dot.radiowaves.forward", tint: HiveInk.violet)
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
            action("Codeplug", icon: "memorychip", panel: .codeplug)
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

    private func capabilitySection(_ title: String, items: [Capability]) -> some View {
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

    private func capabilityTile(_ item: Capability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.icon)
                    .foregroundStyle(item.status.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(2)
                    Text(item.status.title)
                        .font(.caption)
                        .foregroundStyle(item.status.color)
                }
                Spacer(minLength: 0)
            }
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)
            HiveSpectrumRibbon(samples: item.samples, tint: item.status.color)
                .frame(height: 28)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
        .background(HiveInk.panel.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.status.color.opacity(0.22), lineWidth: 1)
        }
    }

    private var rfCapabilities: [Capability] {
        [
            Capability("FCC license packs", "Installed packs browse counties, licensees, frequencies, modes, power, and sites.", "externaldrive.fill", .live),
            Capability("Live SDR spectrum", "Direct USB RTL-SDR on this Mac is the primary path; rtl_tcp, OpenWebRX, HackRF, LimeSDR, SDRplay, Airspy, PlutoSDR, and test sources remain supported source types.", "waveform.path.ecg", .live),
            Capability("AM/NFM/WFM/SSB/CW demodulation", "Shared DSP pipeline exposes \(DemodMode.allCases.map(\.rawValue).joined(separator: ", ")).", "slider.horizontal.3", .live),
            Capability("Radio programming", "Codeplug builder and CHIRP CSV export use frequencies selected from Browse, Search, and Scanner.", "memorychip", .live),
            Capability("Public safety trunking", "OpenMHz system and talkgroup browser with codeplug handoff.", "antenna.radiowaves.left.and.right", .live),
            Capability("Signal finder", "Scanner spectrum peak finder can add active peaks to the codeplug.", "sparkle.magnifyingglass", .live)
        ]
    }

    private var decoderCapabilities: [Capability] {
        [
            Capability("ADS-B 1090", "Mode S / ADS-B decoder types are in the DSP package.", "airplane", .live),
            Capability("UAT 978 weather", "UAT decoder and weather overlay models are present for dump978-style workflows.", "cloud.sun.rain", .live),
            Capability("ACARS", "VHF aviation text decoder is implemented in core DSP.", "teletype", .live),
            Capability("AIS", "Maritime AIS decoder uses the shared AFSK demodulator.", "ferry", .live),
            Capability("Morse / CW", "Morse decoder is implemented for CW lab work.", "dot.circle", .live),
            Capability("P25 / DMR / NXDN metadata", "Temporary dsdccx adapter; target is a Swift-native metadata and voice path.", "person.wave.2", externalToolStatus("dsdccx")),
            Capability("POCSAG / FLEX paging", "Temporary multimon-ng adapter; target is a Swift-native paging demodulator.", "message.badge.waveform", externalToolStatus("multimon-ng")),
            Capability("FT8 / FT4 / WSPR metadata", "Weak-signal parser is implemented; live decode needs a Swift-native audio bridge.", "sparkles", .external)
        ]
    }

    private var hardwareCapabilities: [Capability] {
        [
            Capability("RTL-SDR USB", "Native librtlsdr driver loads from Homebrew, /usr/local, or bundled app resources.", "usb", .live),
            Capability("Network SDR / Raspberry Pi", "Optional remote sources for later Pi field boxes; direct USB RTL-SDR on this Mac remains the default path.", "network", .live),
            Capability("Uniden scanners", "Serial protocol helpers for scanner programming mode exist in core.", "radio", .external),
            Capability("GPS", "Location models are used in sites; live GPS ingest still needs device binding.", "location", .planned),
            Capability("ESP32 / Arduino / Raspberry Pi", "Swift serial, TCP, BLE, and MQTT adapters are planned.", "cpu", .planned),
            Capability("Wi-Fi / Bluetooth / IoT", "Swift packet and BLE modules need platform entitlements and adapter work.", "wifi", .planned)
        ]
    }

    private var plannedCapabilities: [Capability] {
        [
            Capability("NOAA APT weather satellite images", "Needs orbital pass planner, audio capture chain, and APT image renderer.", "satellite", .planned),
            Capability("Meteor / LRPT satellite images", "Needs QPSK demod, deframer, and image product renderer.", "globe.americas", .planned),
            Capability("Satellite radio / TV", "Needs DVB-S/S2 capable hardware path and transport-stream tools.", "tv", .planned),
            Capability("ATSC / ISDB / DVB-T TV", "Needs tuner support beyond standard RTL-SDR IQ capture.", "display", .planned),
            Capability("DMR/P25 trunk following", "Needs control-channel decode, talkgroup following, and audio recorder integration.", "point.3.connected.trianglepath.dotted", .planned),
            Capability("Swift decoder migration", "Replace temporary adapters with original Swift demodulators and parsers where feasible.", "swift", .planned),
            Capability("Radio control profiles", "Needs per-radio CAT/CI-V/serial profile UI and safety limits.", "dial.low", .planned)
        ]
    }

    private func externalToolStatus(_ executable: String) -> CapabilityStatus {
        #if os(macOS)
        let locator = DecoderToolExecutableLocator.live
        if locator.resolveExecutableURL(
            basenames: [executable],
            candidatePaths: ["/opt/homebrew/bin/\(executable)", "/usr/local/bin/\(executable)"]
        ) != nil {
            return .live
        }
        #endif
        return .external
    }

    private var heroSamples: [Double] {
        [0.16, 0.20, 0.18, 0.24, 0.42, 0.23, 0.19, 0.31, 0.82, 0.27, 0.21, 0.34, 0.53, 0.29, 0.24, 0.91, 0.46, 0.28, 0.22, 0.38, 0.74, 0.33, 0.26, 0.20]
    }
}

private struct Capability: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var icon: String
    var status: CapabilityStatus
    var samples: [Double]

    init(_ title: String, _ detail: String, _ icon: String, _ status: CapabilityStatus) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.status = status
        let seed = Double(abs(title.hashValue % 17)) / 30.0
        self.samples = [
            0.12 + seed, 0.18, 0.22 + seed / 2, 0.15, 0.34,
            0.20, 0.68 - seed / 2, 0.24, 0.17, 0.42 + seed,
            0.23, 0.19, 0.78 - seed / 3, 0.28, 0.16
        ].map { min(0.95, max(0.08, $0)) }
    }
}

private enum CapabilityStatus {
    case live
    case external
    case planned

    var title: String {
        switch self {
        case .live: return "Available"
        case .external: return "External adapter"
        case .planned: return "Planned"
        }
    }

    var color: Color {
        switch self {
        case .live: return .green
        case .external: return .orange
        case .planned: return .secondary
        }
    }
}

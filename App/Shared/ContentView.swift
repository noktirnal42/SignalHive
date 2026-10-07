import SwiftUI
import SignalHiveCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AviationModel.self) private var aviation
    @State private var selection: Panel?

    enum Panel: String, CaseIterable, Identifiable {
        case workshop, aiLab, browse, search, trunked, scanner, decoderHub, satellites, airMap, airData, codeplug
        var id: String { rawValue }

        init(_ destination: WorkshopDestination) {
            switch destination {
            case .browse: self = .browse
            case .search: self = .search
            case .scanner: self = .scanner
            case .decoderHub: self = .decoderHub
            case .trunked: self = .trunked
            case .codeplug: self = .codeplug
            case .aiLab: self = .aiLab
            case .satellites: self = .satellites
            case .airMap: self = .airMap
            case .airData: self = .airData
            }
        }

        var title: String {
            switch self {
            case .workshop: return "Workshop"
            case .aiLab: return "AI Lab"
            case .browse: return "Browse"
            case .search: return "Search"
            case .trunked: return "Trunked"
            case .scanner: return "Scanner"
            case .decoderHub: return "Decoder Hub"
            case .satellites: return "Satellites"
            case .airMap: return "Air Map"
            case .airData: return "Air Data"
            case .codeplug: return "Codeplug"
            }
        }

        var icon: String {
            switch self {
            case .workshop: return "radio"
            case .aiLab: return "brain.head.profile"
            case .browse: return "list.bullet.indent"
            case .search: return "magnifyingglass"
            case .trunked: return "antenna.radiowaves.left.and.right"
            case .scanner: return "waveform.path.ecg"
            case .decoderHub: return "dot.radiowaves.forward"
            case .satellites: return "globe.americas"
            case .airMap: return "airplane"
            case .airData: return "doc.text.magnifyingglass"
            case .codeplug: return "memorychip"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Panel.allCases) { panel in
                    Label(panel.title, systemImage: panel.icon)
                        .tag(panel)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("SignalHive")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            switch selection ?? .workshop {
            case .workshop:
                WorkshopView(perform: perform)
            case .aiLab: AILabView()
            case .browse: BrowseView()
            case .search: SearchView()
            case .trunked: TrunkedView()
            case .scanner: ScannerView()
            case .decoderHub: DecoderHubView()
            case .satellites: SatellitesView()
            case .airMap: AirMapView()
            case .airData: AirDataView()
            case .codeplug: CodeplugView()
            }
        }
        .overlay(alignment: .bottom) {
            if model.importActive, let progress = model.importProgress {
                ImportStatusBar(progress: progress) {
                    model.cancelImport()
                }
            }
        }
    }
}

extension ContentView {
    /// The Workshop's open and launch actions. (Fixes and explanations are sheets the Workshop shows itself.)
    private func perform(_ action: WorkshopAction) {
        switch action {
        case let .open(destination):
            selection = Panel(destination)
        case let .launch(destination, preset):
            selection = Panel(destination)
            switch preset {
            case .scannerTune, .decoder:
                // Taken by the Scanner or the Decoder Hub when it appears.
                model.pendingPreset = preset
            case .listenADSB1090:
                #if os(macOS)
                Task { await aviation.start(.adsb1090) }
                #endif
            case .listenUAT978:
                #if os(macOS)
                Task { await aviation.start(.uat978) }
                #endif
            }
        case .fix, .learn:
            break
        }
    }
}

struct ImportStatusBar: View {
    var progress: PackBuildProgress
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: min(1, max(0, progress.fraction)))
                .frame(maxWidth: 320)
            Text(progress.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel", action: onCancel)
                .font(.caption)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 8)
    }
}

import SwiftUI
import SignalHiveCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Panel?

    enum Panel: String, CaseIterable, Identifiable {
        case workshop, aiLab, browse, search, trunked, scanner, airMap, airData, codeplug
        var id: String { rawValue }

        var title: String {
            switch self {
            case .workshop: return "Workshop"
            case .aiLab: return "AI Lab"
            case .browse: return "Browse"
            case .search: return "Search"
            case .trunked: return "Trunked"
            case .scanner: return "Scanner"
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
                WorkshopView { panel in
                    selection = panel
                }
            case .aiLab: AILabView()
            case .browse: BrowseView()
            case .search: SearchView()
            case .trunked: TrunkedView()
            case .scanner: ScannerView()
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

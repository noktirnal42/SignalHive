import SwiftUI
import SignalHiveCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("packBaseURL") private var packBaseURL = ""

    var body: some View {
        Form {
            packsSection
            localBuildSection
            serverSection
            aboutSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var packsSection: some View {
        Section("Installed data") {
            let installed = model.states.filter { if case .installed = $0.status { return true } else { return false } }
            if installed.isEmpty {
                Text("Nothing installed yet. Choose a state in Browse.").foregroundStyle(.secondary)
            }
            ForEach(installed) { state in
                HStack {
                    Text(state.name)
                    Spacer()
                    if case let .installed(snapshot) = state.status {
                        Text("FCC data \(snapshot)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Remove", role: .destructive) { Task { await model.removePack(state: state.code) } }
                        .buttonStyle(.borderless)
                }
            }
            if let error = model.databaseError { Text(error).foregroundStyle(.red) }
            if let error = model.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var localBuildSection: some View {
        Section("Build from FCC on this Mac") {
            Text("Downloads the FCC's weekly public database directly and builds the data on this Mac. Use it when no data server is available.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ULSService.allCases) { service in
                Toggle(isOn: Binding(
                    get: { model.localBuildServices.contains(service.id) },
                    set: { on in
                        if on { model.localBuildServices.insert(service.id) } else { model.localBuildServices.remove(service.id) }
                    }
                )) {
                    HStack {
                        Text(service.displayName)
                        Spacer()
                        Text("~\(service.approximateSizeMB) MB").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button {
                    Task { await model.buildLocally(states: Set(USStateCatalog.states.map(\.code))) }
                } label: {
                    Label(model.importActive ? "Building…" : "Build all states", systemImage: "hammer")
                }
                .disabled(model.importActive || model.localBuildServices.isEmpty)
                if model.importActive { Button("Cancel") { model.cancelImport() } }
            }
            if let progress = model.importProgress {
                VStack(alignment: .leading) {
                    Text(progress.phase).font(.caption)
                    ProgressView(value: min(1, max(0, progress.fraction)))
                }
            }
            if let summary = model.lastImportSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var serverSection: some View {
        Section("Data server (advanced)") {
            TextField("https://example.com/packs", text: $packBaseURL)
            Text(model.manifestNote ?? "Data server reachable. Changes apply the next time the app opens.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 4) {
                Text("SignalHive").font(.headline)
                Text(DataAttribution.fccNotice).font(.caption).foregroundStyle(.secondary)
                ForEach(DataAttribution.sources, id: \.self) { source in
                    Text("• \(source)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

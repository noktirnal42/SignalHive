import SwiftUI
import SignalHiveCore

struct TrunkedView: View {
    @Environment(AppModel.self) private var model
    @State private var systems: [TrunkedSystem] = []
    @State private var loading = false
    @State private var selectedSystem: TrunkedSystem?
    @State private var talkgroups: [TrunkedTalkgroup] = []
    @State private var loadingTGs = false
    @State private var error: String?

    var body: some View {
        NavigationSplitView {
            systemList
        } detail: {
            talkgroupList
        }
        .navigationTitle("Trunked")
        .task { if systems.isEmpty { await loadSystems() } }
    }

    private var systemList: some View {
        List(selection: Binding(
            get: { selectedSystem?.shortName },
            set: { shortName in
                selectedSystem = systems.first { $0.shortName == shortName }
                Task { await loadTalkgroups() }
            }
        )) {
            if loading {
                ProgressView()
            } else if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Could not load OpenMHz systems")
                        .font(.callout)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await loadSystems() }
                    }
                }
            } else if systems.isEmpty {
                Text("No trunked systems available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(systems) { system in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(system.name)
                            .font(.body)
                        HStack {
                            Text(system.shortName)
                                .font(.caption.monospaced())
                            Spacer()
                            Text("\(system.talkgroupCount) TGs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(system.shortName)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var talkgroupList: some View {
        List {
            if let system = selectedSystem {
                Section(system.name) {
                    if loadingTGs {
                        ProgressView()
                    } else if talkgroups.isEmpty {
                        Text("No talkgroups on file")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(talkgroups) { tg in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tg.alphaTag.isEmpty ? tg.descriptionText : tg.alphaTag)
                                        .font(.body)
                                    Text(tg.descriptionText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(tg.code)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button {
                                    model.addToCodeplug(channel: CodeplugChannel(
                                        name: String((tg.alphaTag.isEmpty ? "TG\(tg.code)" : tg.alphaTag).prefix(7)),
                                        frequencyHz: 0,
                                        mode: .p25,
                                        talkgroupID: tg.code,
                                        notes: system.name,
                                        sourceCallSign: system.shortName
                                    ))
                                } label: {
                                    Label("Add", systemImage: "plus.memorychip")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            } else {
                Text("Select a system")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadSystems() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            systems = try await OpenMHzClient.systems()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadTalkgroups() async {
        guard let system = selectedSystem else { return }
        loadingTGs = true
        defer { loadingTGs = false }
        talkgroups = (try? await OpenMHzClient.talkgroups(systemShortName: system.shortName)) ?? []
    }
}

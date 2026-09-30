import SwiftUI
import SignalHiveCore

/// One place to get FCC data for any number of states: pick them, see what the job will download, start it, watch it.
/// States that have to be built on this device share a single download of the FCC archives.
struct GetDataSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String>
    @State private var search = ""
    @State private var preference: DataSourcePreference = .automatic
    @State private var refreshInstalled = false

    init(preselected: Set<String> = []) {
        _selection = State(initialValue: preselected)
    }

    private var plan: DataPlan {
        model.dataPlan(for: selection, preference: preference, refreshInstalled: refreshInstalled)
    }

    private var visibleStates: [StateAvailability] {
        let words = search.lowercased().split(whereSeparator: { $0.isWhitespace })
        return model.states.filter { state in
            words.allSatisfy { state.name.lowercased().contains($0) || state.code.lowercased() == String($0) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let job = model.dataJob {
                    jobPanel(job)
                } else {
                    chooser
                }
            }
            .navigationTitle("Get FCC data")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.dataJobRunning ? "Hide" : "Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 620)
        #endif
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search states", text: $search)
                    .textFieldStyle(.roundedBorder)
                Menu("Select") {
                    Button("Everything not installed") { selectAll { if case .installed = $0 { return false } else { return true } } }
                    Button("Failed") { selectAll { if case .failed = $0 { return true } else { return false } } }
                    Button("Installed (to update)") {
                        refreshInstalled = true
                        selectAll { if case .installed = $0 { return true } else { return false } }
                    }
                    Divider()
                    Button("Nothing") { selection = [] }
                }
            }
            .padding(12)

            List {
                Section {
                    ForEach(visibleStates) { state in
                        row(state)
                    }
                } footer: {
                    Text("\(selection.count) selected")
                }
                if !selection.isEmpty { optionsSection }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(plan.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = model.manifestNote, preference == .automatic {
                    Label("Hosted packs are unavailable (\(note)); states will be built from FCC data.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    let chosen = plan
                    Task { await model.getData(chosen) }
                } label: {
                    Label(plan.isEmpty ? "Get data" : "Get \(plan.downloads.count + plan.builds.count) state\(plan.downloads.count + plan.builds.count == 1 ? "" : "s")",
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(plan.isEmpty || model.importActive)
                if model.importActive {
                    Text("A build from the Settings screen is running; wait for it to finish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func row(_ state: StateAvailability) -> some View {
        let status = model.status(for: state.code)
        let chosen = selection.contains(state.code)
        return Button {
            if chosen { selection.remove(state.code) } else { selection.insert(state.code) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                Text(state.name)
                Spacer()
                Text(Self.statusText(status))
                    .font(.caption)
                    .foregroundStyle(Self.isInstalled(status) ? Color.green : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var optionsSection: some View {
        Section("Options") {
            Picker("Source", selection: $preference) {
                ForEach(DataSourcePreference.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Also update states that are already installed", isOn: $refreshInstalled)
            if !plan.builds.isEmpty {
                DisclosureGroup("FCC data to include when building") {
                    ForEach(ULSService.allCases) { service in
                        Toggle(isOn: serviceBinding(service)) {
                            VStack(alignment: .leading) {
                                Text(service.displayName)
                                Text("about \(service.approximateSizeMB) MB")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func serviceBinding(_ service: ULSService) -> Binding<Bool> {
        Binding(get: { model.localBuildServices.contains(service.id) },
                set: { on in
                    if on { model.localBuildServices.insert(service.id) } else { model.localBuildServices.remove(service.id) }
                })
    }

    private func selectAll(where matches: (PackStatus) -> Bool) {
        selection = Set(model.states.filter { matches(model.status(for: $0.code)) }.map(\.code))
    }

    // MARK: Running

    private func jobPanel(_ job: AppModel.DataJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if job.isRunning {
                ProgressView(value: Double(job.completedCount), total: Double(max(1, job.totalCount))) {
                    Text("\(job.completedCount) of \(job.totalCount) states")
                        .font(.headline)
                }
                Text(job.step).font(.callout).foregroundStyle(.secondary)
                if model.importActive, let progress = model.importProgress {
                    ProgressView(value: min(1, max(0, progress.fraction)))
                    Text(progress.phase).font(.caption).foregroundStyle(.secondary)
                }
            } else if let summary = job.summary {
                Label(summary, systemImage: job.failures.isEmpty && !job.wasCancelled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(job.failures.isEmpty && !job.wasCancelled ? Color.green : Color.orange)
            }

            List {
                let all = job.plan.downloads + job.plan.builds
                ForEach(all) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        if job.finished.contains(item.code) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if let reason = job.failures[item.code] {
                            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
                        } else if job.isRunning {
                            Text(Self.statusText(model.status(for: item.code))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                if job.isRunning {
                    Button("Cancel", role: .cancel) { model.cancelDataJob() }
                } else {
                    Button("Get more states") { model.dismissDataJob() }
                    Spacer()
                    Button("Done") {
                        model.dismissDataJob()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }

    // MARK: Words

    private static func isInstalled(_ status: PackStatus) -> Bool {
        if case .installed = status { return true }
        return false
    }

    static func statusText(_ status: PackStatus) -> String {
        switch status {
        case let .installed(snapshot): return "Installed \(snapshot)"
        case let .downloading(progress): return "Downloading \(Int(progress * 100))%"
        case .verifying: return "Verifying"
        case .failed: return "Failed"
        case let .notInstalled(size):
            return size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Build from FCC data"
        }
    }
}

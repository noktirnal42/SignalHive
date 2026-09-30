import SwiftUI
import SignalHiveCore

struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedStateCode: String?
    @State private var selectedCounty: CountyID?
    @State private var selectedLicenseUID: Int64?
    @State private var counties: [CountySummary] = []
    @State private var licenses: [LicenseSummary] = []
    @State private var loadingCounties = false
    @State private var loadingLicenses = false
    @State private var loadError: String?
    @State private var didSelectDefaultState = false
    @State private var showGetData = false

    var body: some View {
        browseLayout
            .navigationTitle("Browse")
            .task(id: countyLoadKey) { await loadCounties() }
            .task(id: selectedCounty) { await loadLicenses() }
            .onChange(of: model.states) { _, _ in selectDefaultStateIfNeeded() }
            .onChange(of: selectedStateCode) { _, _ in
                selectedCounty = nil
                selectedLicenseUID = nil
                licenses = []
            }
            .onChange(of: selectedCounty) { _, _ in
                selectedLicenseUID = nil
                licenses = []
            }
            .task { selectDefaultStateIfNeeded() }
            .toolbar {
                ToolbarItem {
                    Button {
                        showGetData = true
                    } label: {
                        Label(model.dataJobRunning ? "Getting data…" : "Get Data", systemImage: "arrow.down.circle")
                    }
                    .help("Download or build FCC data for one or more states")
                }
            }
            .sheet(isPresented: $showGetData) {
                GetDataSheet(preselected: preselection)
            }
    }

    /// The state being looked at, when it still needs data.
    private var preselection: Set<String> {
        guard let code = selectedStateCode else { return [] }
        if case .installed = model.status(for: code) { return [] }
        return [code]
    }

    @ViewBuilder
    private var browseLayout: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            stateColumn
                .frame(width: 300)
            Divider()
            countyColumn
                .frame(width: 380)
            Divider()
            licenseColumn
                .frame(maxWidth: .infinity)
        }
        #else
        NavigationSplitView {
            stateColumn
        } content: {
            countyColumn
        } detail: {
            licenseColumn
        }
        #endif
    }

    private var selectedStatus: PackStatus? {
        selectedStateCode.map { model.status(for: $0) }
    }

    /// Reload counties when the selection changes or the selected state's pack becomes installed.
    private var countyLoadKey: String {
        guard let code = selectedStateCode else { return "" }
        if case let .installed(snapshot) = model.status(for: code) { return "\(code)-\(snapshot)" }
        return "\(code)-pending"
    }

    // MARK: Columns

    private var stateColumn: some View {
        List(selection: $selectedStateCode) {
            Section("States") {
                ForEach(model.states) { state in
                    stateRow(state)
                    .tag(state.code)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    }

    private func stateRow(_ state: StateAvailability) -> some View {
        HStack(spacing: 10) {
            statusIcon(model.status(for: state.code))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.name)
                    .lineLimit(1)
                Text(statusLabel(model.status(for: state.code)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ status: PackStatus) -> some View {
        switch status {
        case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading, .verifying: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .notInstalled: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: PackStatus) -> String {
        switch status {
        case let .installed(snapshot): return "Installed \(snapshot)"
        case let .downloading(progress): return "Downloading \(Int(progress * 100))%"
        case .verifying: return "Verifying"
        case let .failed(reason): return reason
        case let .notInstalled(sizeBytes):
            if let sizeBytes {
                return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            }
            return "Build locally"
        }
    }

    private var countyColumn: some View {
        Group {
            if let code = selectedStateCode, let status = selectedStatus {
                switch status {
                case .installed: installedCounties(code)
                case let .notInstalled(size): notInstalled(code, size: size)
                case let .downloading(progress): busy("Downloading data for \(name(code))…", progress: progress)
                case .verifying: busy("Verifying…", progress: nil)
                case let .failed(reason): failed(code, reason: reason)
                }
            } else {
                ContentUnavailableView("Select a State", systemImage: "hand.tap",
                                       description: Text("Choose a state to browse its counties and licensed frequencies."))
            }
        }
    }

    private func installedCounties(_ code: String) -> some View {
        List(selection: $selectedCounty) {
            Section(name(code)) {
                if loadingCounties {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Could not load counties", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") { Task { await loadCounties() } }
                    }
                } else if counties.isEmpty {
                    Text("No licensed sites found for \(name(code)).").foregroundStyle(.secondary)
                } else {
                    ForEach(counties) { county in
                        HStack {
                            Label(county.name, systemImage: "map")
                            Spacer()
                            Text("\(county.licenseCount)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(county.id)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
    }

    private func notInstalled(_ code: String, size: Int64?) -> some View {
        ContentUnavailableView {
            Label("\(name(code)) data not installed", systemImage: "arrow.down.circle")
        } description: {
            VStack(spacing: 6) {
                Text("Frequencies and licenses come from the FCC's public database.")
                if let note = model.manifestNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if model.importActive, let progress = model.importProgress {
                    ProgressView(value: min(1, max(0, progress.fraction)))
                    Text(progress.phase).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        } actions: {
            if model.manifestNote == nil {
                Button {
                    Task { await model.install(state: code) }
                } label: {
                    Label(size.map { "Download (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? "Download",
                          systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                Task { await model.buildLocally(states: [code]) }
            } label: {
                Label("Build from FCC on this Mac", systemImage: "hammer")
            }
            .disabled(model.importActive || model.dataJobRunning)
            Button {
                showGetData = true
            } label: {
                Label("Get several states at once…", systemImage: "square.stack.3d.down.right")
            }
        }
    }

    private func busy(_ text: String, progress: Double?) -> some View {
        VStack(spacing: 12) {
            if let progress { ProgressView(value: progress).frame(maxWidth: 240) } else { ProgressView() }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ code: String, reason: String) -> some View {
        ContentUnavailableView {
            Label("Could not install \(name(code))", systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        } actions: {
            Button("Try Again") { Task { await model.install(state: code) } }
            Button("Build from FCC on this Mac") { Task { await model.buildLocally(states: [code]) } }
        }
    }

    private var licenseColumn: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            licenseList
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 500)
            Divider()
            licenseDetailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewColumnWidth(min: 620, ideal: 760)
        #else
        licenseNavigationList
            .navigationDestination(for: Int64.self) { uid in FrequencyDetailView(uid: uid) }
            .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        #endif
    }

    private var licenseList: some View {
        List(selection: $selectedLicenseUID) {
            licenseListContent
        }
    }

    private var licenseNavigationList: some View {
        List {
            licenseListContent
        }
    }

    @ViewBuilder
    private var licenseListContent: some View {
        #if os(macOS)
        if selectedCounty == nil {
            ContentUnavailableView("Select a County", systemImage: "map",
                                   description: Text("Choose a county to list licenses and frequencies."))
        } else if loadingLicenses {
            ProgressView()
        } else if licenses.isEmpty {
            ContentUnavailableView("No Licenses", systemImage: "antenna.radiowaves.left.and.right.slash")
        } else {
            Section("Licenses") {
                ForEach(licenses) { license in
                    licenseRow(license)
                        .tag(license.uid)
                }
            }
        }
        #else
            if selectedCounty == nil {
                ContentUnavailableView("Select a County", systemImage: "map",
                                       description: Text("Choose a county to list licenses and frequencies."))
            } else if loadingLicenses {
                ProgressView()
            } else if licenses.isEmpty {
                ContentUnavailableView("No Licenses", systemImage: "antenna.radiowaves.left.and.right.slash")
            } else {
                ForEach(licenses) { license in
                    NavigationLink(value: license.uid) {
                        licenseRow(license)
                    }
                }
            }
        #endif
    }

    private func licenseRow(_ license: LicenseSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(license.licenseeName.isEmpty ? license.callSign : license.licenseeName)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(license.callSign).font(.caption.monospaced())
                Text(license.serviceName).font(.caption)
                    .lineLimit(1)
                ForEach(license.modeHints.filter { $0 != .unknown }, id: \.self) { hint in
                    Text(hint.displayName).font(.caption2).padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text("\(license.frequencyCount) freq").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var licenseDetailPane: some View {
        if let selectedLicenseUID {
            FrequencyDetailView(uid: selectedLicenseUID)
                .id(selectedLicenseUID)
        } else if selectedCounty == nil {
            ContentUnavailableView("Select a County", systemImage: "map",
                                   description: Text("Choose a county to reveal licenses and frequency details."))
        } else {
            ContentUnavailableView("Select a License", systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text("Pick a license to see its frequencies, sites, and radio actions."))
        }
    }

    // MARK: Loading

    private func name(_ code: String) -> String {
        model.states.first { $0.code == code }?.name ?? code
    }

    private func selectDefaultStateIfNeeded() {
        guard !didSelectDefaultState, !model.states.isEmpty else { return }
        didSelectDefaultState = true
        if let installed = model.states.first(where: { if case .installed = $0.status { return true } else { return false } }) {
            selectedStateCode = installed.code
        } else {
            selectedStateCode = model.states.first?.code
        }
    }

    private func loadCounties() async {
        guard let code = selectedStateCode, case .installed = model.status(for: code) else {
            counties = []
            return
        }
        loadingCounties = true
        loadError = nil
        defer { loadingCounties = false }
        do {
            counties = try await model.browse.counties(in: code)
        } catch {
            counties = []
            loadError = error.localizedDescription
        }
    }

    private func loadLicenses() async {
        guard let county = selectedCounty else {
            licenses = []
            return
        }
        loadingLicenses = true
        defer { loadingLicenses = false }
        do {
            licenses = try await model.browse.licenses(in: county, filter: .none)
            if selectedLicenseUID.map({ uid in licenses.contains { $0.uid == uid } }) != true {
                selectedLicenseUID = licenses.first?.uid
            }
        } catch {
            licenses = []
            selectedLicenseUID = nil
            model.lastError = error.localizedDescription
        }
    }
}

import SwiftUI
import SignalHiveCore

struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedState: USState?
    @State private var selectedCounty: USCounty?
    @State private var counties: [(county: USCounty, count: Int)] = []
    @State private var licenses: [AppDatabase.LicenseListing] = []
    @State private var selectedLicenseUID: Int64?
    @State private var loadingCounties = false
    @State private var loadingLicenses = false

    var body: some View {
        browseSplit
            .navigationTitle("Browse")
            .task { await loadStates() }
            .onChange(of: selectedState) { _, _ in Task { await loadCounties() } }
            .onChange(of: selectedCounty) { _, _ in Task { await loadLicenses() } }
    }

    private var browseSplit: some View {
        NavigationSplitView {
            stateColumn
        } content: {
            countyColumn
        } detail: {
            licenseColumn
        }
    }

    private var stateSelection: Binding<String?> {
        Binding(
            get: { selectedState?.code },
            set: { code in
                guard let code else {
                    selectedState = nil
                    selectedCounty = nil
                    return
                }
                guard let found = USStateCatalog.states.first(where: { $0.code == code }) else { return }
                selectedState = USState(code: found.code, name: found.name)
                selectedCounty = nil
            }
        )
    }

    private var countySelection: Binding<String?> {
        Binding(
            get: { selectedCounty?.id },
            set: { id in
                selectedCounty = counties.first { $0.county.id == id }?.county
            }
        )
    }

    private var stateColumn: some View {
        List(selection: stateSelection) {
            Section("States") {
                ForEach(USStateCatalog.states, id: \.code) { state in
                    Label(state.name, systemImage: "mappin.and.ellipse")
                        .tag(state.code)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var countyColumn: some View {
        List(selection: countySelection) {
            if let state = selectedState {
                Section(state.name) {
                    if loadingCounties {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else if counties.isEmpty {
                        ContentUnavailableView {
                            Label("No Data", systemImage: "antenna.radiowaves.left.and.right.slash")
                        } description: {
                            VStack(spacing: 8) {
                                Text("No licensed locations found for \(state.name).")
                                Text("Import FCC ULS data to populate the database.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } actions: {
                            Button {
                                // Open Settings to import
                                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                            } label: {
                                Label("Import ULS Data", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ForEach(counties, id: \.county.id) { entry in
                            HStack {
                                Label(entry.county.county, systemImage: "map")
                                Spacer()
                                Text("\(entry.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(entry.county.id)
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Select a State", systemImage: "hand.tap")
                } description: {
                    Text("Choose a state from the sidebar to view its counties with licensed frequencies.")
                }
            }
        }
    }

    private var licenseColumn: some View {
        List {
            if selectedCounty == nil {
                Text("Select a county")
                    .foregroundStyle(.secondary)
            } else if loadingLicenses {
                ProgressView()
            } else {
                ForEach(licenses) { license in
                    NavigationLink(value: license.uid) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(license.licenseeName.isEmpty ? license.callSign : license.licenseeName)
                                .font(.body)
                            HStack(spacing: 6) {
                                Text(license.callSign)
                                    .font(.caption.monospaced())
                                Text(license.serviceName)
                                    .font(.caption)
                                Text(license.statusName)
                                    .font(.caption)
                                    .foregroundStyle(license.statusName == "Active" ? .green : .secondary)
                                Spacer()
                                Text("\(license.frequencyCount) freq")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationDestination(for: Int64.self) { uid in
            FrequencyDetailView(uid: uid)
        }
    }

    private func loadStates() async {
        // States are seeded at bootstrap; nothing else needed here.
    }

    private func loadCounties() async {
        guard let database = model.database, let state = selectedState else { return }
        loadingCounties = true
        defer { loadingCounties = false }
        counties = (try? await database.countiesWithLicenseCounts(in: state.code)) ?? []
    }

    private func loadLicenses() async {
        guard let database = model.database, let state = selectedState, let county = selectedCounty else { return }
        loadingLicenses = true
        defer { loadingLicenses = false }
        licenses = (try? await database.licenses(in: state.code, county: county.county, service: nil)) ?? []
    }
}

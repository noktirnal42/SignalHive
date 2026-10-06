import SwiftUI
import SignalHiveCore

/// What the Trunked browser has loaded and how it is filtered. OpenMHz is the source; a saved copy stands in when the
/// network is not available.
@Observable @MainActor
final class TrunkedModel {
    private let repository = TrunkedRepository()

    var systems: [TrunkedSystem] = []
    var systemsSavedAt: Date?
    var systemsSeeded = false
    var systemsNetworkError: String?
    var systemsError: String?
    var loadingSystems = false
    var filter = TrunkedSystemFilter()

    var selectedSystemID: String?
    var talkgroups: [TrunkedTalkgroup] = []
    var talkgroupsSavedAt: Date?
    var talkgroupsSeeded = false
    var talkgroupsNetworkError: String?
    var talkgroupsError: String?
    var loadingTalkgroups = false
    var talkgroupSearch = ""
    var category: TalkgroupCategory?

    private var talkgroupLoad: Task<Void, Never>?

    var selectedSystem: TrunkedSystem? { systems.first { $0.shortName == selectedSystemID } }
    var visibleSystems: [TrunkedSystem] { filter.apply(to: systems) }
    var groups: [TalkgroupGroup] { TalkgroupBrowsing.groups(talkgroups, search: talkgroupSearch, category: category) }
    var categoryCounts: [TalkgroupCategory: Int] { TalkgroupBrowsing.counts(talkgroups) }

    func loadSystems() async {
        loadingSystems = true
        systemsError = nil
        defer { loadingSystems = false }
        do {
            let load = try await repository.systems()
            systems = load.value
            systemsSavedAt = load.savedAt
            systemsSeeded = load.isSeeded
            systemsNetworkError = load.networkError
        } catch {
            systemsError = error.localizedDescription
        }
    }

    func select(_ shortName: String?) {
        guard shortName != selectedSystemID else { return }
        selectedSystemID = shortName
        talkgroups = []
        talkgroupsError = nil
        talkgroupsNetworkError = nil
        talkgroupsSavedAt = nil
        talkgroupsSeeded = false
        talkgroupSearch = ""
        category = nil
        loadingTalkgroups = false
        talkgroupLoad?.cancel()
        talkgroupLoad = Task { await loadTalkgroups() }
    }

    func loadTalkgroups() async {
        guard let name = selectedSystemID else { return }
        loadingTalkgroups = true
        talkgroupsError = nil
        defer { if selectedSystemID == name { loadingTalkgroups = false } }
        do {
            let load = try await repository.talkgroups(system: name)
            guard selectedSystemID == name, !Task.isCancelled else { return }
            talkgroups = load.value
            talkgroupsSavedAt = load.savedAt
            talkgroupsSeeded = load.isSeeded
            talkgroupsNetworkError = load.networkError
        } catch {
            guard selectedSystemID == name, !Task.isCancelled else { return }
            talkgroups = []
            talkgroupsError = error.localizedDescription
        }
    }
}

struct TrunkedView: View {
    @Environment(AppModel.self) private var app
    @State private var model = TrunkedModel()
    @State private var selectedTalkgroups: Set<String> = []
    @State private var addedNote: String?
    @State private var rfCoachRequest: RFCoachRequest?

    var body: some View {
        trunkedLayout
        .navigationTitle("Trunked")
        .task { if model.systems.isEmpty { await model.loadSystems() } }
        .sheet(item: $rfCoachRequest) { request in
            RFCoachSheet(request: request)
        }
    }

    @ViewBuilder
    private var trunkedLayout: some View {
        #if os(macOS)
        // A split view nested inside the app's own split view left about 200 pt of dead space ahead of the
        // talkgroups; Browse uses plain columns for the same reason.
        HStack(spacing: 0) {
            systemList
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
            Divider()
            talkgroupList
                .frame(maxWidth: .infinity)
        }
        #else
        NavigationSplitView {
            systemList
        } detail: {
            talkgroupList
        }
        #endif
    }

    // MARK: Systems

    private var systemList: some View {
        @Bindable var model = model
        return List(selection: Binding(get: { model.selectedSystemID }, set: { model.select($0); selectedTalkgroups = []; addedNote = nil })) {
            if let note = offlineNote(savedAt: model.systemsSavedAt, isSeeded: model.systemsSeeded, error: model.systemsNetworkError) {
                Label(note, systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if model.loadingSystems && model.systems.isEmpty {
                HStack { ProgressView(); Text("Loading OpenMHz systems…").foregroundStyle(.secondary) }
            } else if let error = model.systemsError {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Could not load OpenMHz systems").font(.callout)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.loadSystems() } }
                }
            } else if model.visibleSystems.isEmpty {
                Text(model.systems.isEmpty ? "No trunked systems available" : "No systems match")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.visibleSystems) { system in
                    SystemRow(system: system).tag(system.shortName)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.filter.search, prompt: "Search systems")
        .toolbar {
            ToolbarItem { filterMenu }
            ToolbarItem {
                Button { Task { await model.loadSystems() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(model.loadingSystems)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.systems.isEmpty {
                Text("\(model.visibleSystems.count) of \(model.systems.count) systems")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    private var filterMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Order", selection: $model.filter.order) {
                ForEach(TrunkedSystemFilter.Order.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Active systems only", isOn: $model.filter.activeOnly)
            Menu("State") {
                ForEach(TrunkedSystemFilter.states(in: model.systems), id: \.self) { state in
                    Toggle(state, isOn: setBinding(state, in: $model.filter.states))
                }
                Button("All states") { model.filter.states = [] }
            }
            Menu("System type") {
                ForEach(TrunkedSystemFilter.types(in: model.systems), id: \.self) { type in
                    Toggle(type.uppercased(), isOn: setBinding(type, in: $model.filter.types))
                }
                Button("All types") { model.filter.types = [] }
            }
        } label: {
            Label("Filter", systemImage: hasFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var hasFilter: Bool {
        !model.filter.states.isEmpty || !model.filter.types.isEmpty || model.filter.activeOnly
    }

    private func setBinding(_ value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) },
                set: { on in if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
    }

    // MARK: Talkgroups

    private var talkgroupList: some View {
        Group {
            if let system = model.selectedSystem {
                talkgroupContent(for: system)
            } else {
                ContentUnavailableView("Select a system", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Pick a trunked system to browse its talkgroups."))
            }
        }
    }

    private func talkgroupContent(for system: TrunkedSystem) -> some View {
        @Bindable var model = model
        return List(selection: $selectedTalkgroups) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(system.name).font(.headline)
                    Text([system.typeLabel, system.location].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !system.details.isEmpty {
                        Text(system.details).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let note = offlineNote(savedAt: model.talkgroupsSavedAt, isSeeded: model.talkgroupsSeeded, error: model.talkgroupsNetworkError) {
                    Label(note, systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
                }
                if let addedNote {
                    Label(addedNote, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                }
                categoryChips
            }

            if model.loadingTalkgroups && model.talkgroups.isEmpty {
                HStack { ProgressView(); Text("Loading talkgroups…").foregroundStyle(.secondary) }
            } else if let error = model.talkgroupsError {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Could not load talkgroups").font(.callout)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.loadTalkgroups() } }
                }
            } else if model.groups.isEmpty {
                Text(model.talkgroups.isEmpty ? "No talkgroups on file for this system" : "No talkgroups match")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.talkgroups) { talkgroup in
                            TalkgroupRow(talkgroup: talkgroup) {
                                explain(talkgroup, on: system)
                            }
                                .tag(talkgroup.id)
                                .swipeActions {
                                    Button { add([talkgroup], on: system) } label: { Label("Add", systemImage: "rectangle.stack.badge.plus") }
                                        .tint(.blue)
                                }
                                .contextMenu {
                                    Button { explain(talkgroup, on: system) } label: { Label("Explain with RF Coach", systemImage: "sparkles") }
                                    Button { add([talkgroup], on: system) } label: { Label("Add to codeplug", systemImage: "rectangle.stack.badge.plus") }
                                }
                        }
                    } header: {
                        Label("\(group.category.displayName) (\(group.talkgroups.count))", systemImage: group.category.symbolName)
                    }
                }
            }
        }
        // Not `.searchable`: the system list already owns the window's one search toolbar item, and a second one in the
        // detail column makes NSToolbar throw (a crash on macOS the moment a system is selected).
        .safeAreaInset(edge: .top, spacing: 0) { talkgroupSearchField(text: $model.talkgroupSearch) }
        .toolbar {
            #if os(iOS)
            ToolbarItem { EditButton() }
            #endif
            ToolbarItem {
                Button {
                    let chosen = model.talkgroups.filter { selectedTalkgroups.contains($0.id) }
                    add(chosen, on: system)
                    selectedTalkgroups = []
                } label: {
                    Label(selectedTalkgroups.isEmpty ? "Add to codeplug" : "Add \(selectedTalkgroups.count) to codeplug",
                          systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(selectedTalkgroups.isEmpty)
            }
        }
    }

    private func talkgroupSearchField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search talkgroups", text: text)
                .textFieldStyle(.plain)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private var categoryChips: some View {
        let counts = model.categoryCounts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                chip("All", symbol: "square.grid.2x2", count: model.talkgroups.count, selected: model.category == nil) { model.category = nil }
                ForEach(TalkgroupCategory.allCases.filter { (counts[$0] ?? 0) > 0 }, id: \.self) { category in
                    chip(category.displayName, symbol: category.symbolName, count: counts[category] ?? 0, selected: model.category == category) {
                        model.category = model.category == category ? nil : category
                    }
                }
            }
        }
    }

    private func chip(_ title: String, symbol: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("\(title) \(count)", systemImage: symbol)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func add(_ talkgroups: [TrunkedTalkgroup], on system: TrunkedSystem) {
        guard !talkgroups.isEmpty else { return }
        let added = app.addTalkgroups(talkgroups, on: system)
        let skipped = talkgroups.count - added
        var note = "Added \(added) talkgroup\(added == 1 ? "" : "s") to \(app.codeplug.name)"
        if skipped > 0 { note += " (\(skipped) already there)" }
        if !app.codeplug.target.supportsTalkgroups {
            note += ". The \(app.codeplug.target.rawValue) cannot follow trunked systems; Codeplug will flag them."
        }
        addedNote = note
    }

    private func explain(_ talkgroup: TrunkedTalkgroup, on system: TrunkedSystem) {
        let serviceParts = [
            talkgroup.category.displayName,
            talkgroup.tag,
            talkgroup.group
        ].filter { !$0.isEmpty }
        rfCoachRequest = RFCoachRequest(
            title: "\(talkgroup.displayName) · TG \(talkgroup.code)",
            subtitle: [system.name, system.typeLabel, system.location].filter { !$0.isEmpty }.joined(separator: " · "),
            context: SignalDescriptionContext(
                frequencyHz: 0,
                licensee: system.name,
                serviceName: serviceParts.joined(separator: " / "),
                trunkedSystemName: system.name,
                talkgroupCode: talkgroup.code,
                contextNote: "OpenMHz talkgroup metadata does not include control-channel or voice-channel frequencies."
            ),
            operatorNote: "This explains the talkgroup role and codeplug impact. Use a control-channel/decoder workflow for live trunk following."
        )
    }

    private func offlineNote(savedAt: Date?, isSeeded: Bool, error: String?) -> String? {
        if isSeeded {
            return "Starter directory: OpenMHz live data is unavailable." + (error.map { " (\($0))" } ?? "")
        }
        guard let savedAt else { return nil }
        let when = savedAt.formatted(date: .abbreviated, time: .shortened)
        return "Offline: showing the copy saved \(when)." + (error.map { " (\($0))" } ?? "")
    }
}

private struct SystemRow: View {
    let system: TrunkedSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(system.name).font(.body)
                if !system.isActive {
                    Text("idle").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if !system.typeLabel.isEmpty {
                    Text(system.typeLabel).font(.caption2.bold())
                }
                Text(system.location.isEmpty ? system.shortName : system.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if system.callsPerHour > 0 {
                    Text("\(Int(system.callsPerHour.rounded())) calls/h").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TalkgroupRow: View {
    let talkgroup: TrunkedTalkgroup
    var onExplain: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(talkgroup.displayName).font(.body)
                let detail = [talkgroup.descriptionText, talkgroup.tag].filter { !$0.isEmpty && $0 != talkgroup.displayName }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onExplain) {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("Explain with RF Coach")
            Text("\(talkgroup.code)").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

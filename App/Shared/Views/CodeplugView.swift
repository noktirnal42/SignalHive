import SwiftUI
import UniformTypeIdentifiers
import SignalHiveCore

struct CodeplugView: View {
    @Environment(AppModel.self) private var model
    @State private var exportText: String?
    @State private var showExportShare = false
    @State private var writeStatus: String?
    @State private var writing = false
    @State private var showNewPlug = false
    @State private var newPlugName = ""
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var editing: CodeplugChannel?
    @State private var showImporter = false
    @State private var importStatus: String?
    @State private var fixStatus: String?
    @State private var reviewSnapshot: ReviewSnapshot?
    @State private var fixPreview: FixPreview?

    private struct ReviewSnapshot: Identifiable {
        let id = UUID()
        let review: CodeplugReview
    }

    private struct FixPreview: Identifiable {
        let id = UUID()
        let plan: CodeplugFixPlan
    }

    var body: some View {
        let review = CodeplugReview.make(for: model.codeplug)
        let issues = review.issues
        List {
            codeplugSection
            if !model.codeplug.channels.isEmpty { checksSection(issues, review: review) }
            channelsSection(issues)
            actionsSection
            if let writeStatus {
                Section {
                    Text(writeStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Codeplug")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editing = CodeplugChannel(name: "", frequencyHz: 0)
                } label: {
                    Label("Add channel", systemImage: "plus.circle")
                }
                Button {
                    showNewPlug = true
                } label: {
                    Label("New codeplug", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewPlug) { newPlugSheet }
        .sheet(item: $reviewSnapshot) { snapshot in
            AIAnswerSheet(
                navigationTitle: "Codeplug review",
                title: snapshot.review.headline,
                subtitle: snapshot.review.codeplugName,
                note: "The assistant explains the findings. It never changes the codeplug: fixes are previewed and applied by you.",
                makeRequest: { .review(snapshot.review, preferred: $0) },
                identity: snapshot.id)
        }
        .sheet(item: $fixPreview) { preview in
            CodeplugFixSheet(plan: preview.plan, codeplugName: model.codeplug.name) {
                let count = preview.plan.changes.count
                if model.applyCodeplugFix(preview.plan) {
                    fixStatus = "Applied \(count) change\(count == 1 ? "" : "s"). Undo is available below."
                } else {
                    fixStatus = "The codeplug changed since the preview, so nothing was applied. Preview the fixes again."
                }
            }
        }
        .sheet(isPresented: $showExportShare) {
            if let exportText {
                ExportSheet(csvText: exportText, fileName: "\(model.codeplug.name)-\(model.codeplug.target.rawValue.replacingOccurrences(of: " ", with: "-")).csv")
            }
        }
        .sheet(item: $editing) { channel in
            ChannelEditor(channel: channel, target: model.codeplug.target,
                          isNew: !model.codeplug.channels.contains { $0.id == channel.id }) { saved in
                if model.codeplug.channels.contains(where: { $0.id == saved.id }) {
                    model.updateChannel(saved)
                } else {
                    model.addToCodeplug(channel: saved)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importCSV(result)
        }
        .alert("Rename codeplug", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") { model.renameCodeplug(renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \"\(model.codeplug.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete codeplug", role: .destructive) { model.deleteCodeplug(model.codeplug.id) }
        } message: {
            Text("Its \(model.codeplug.channels.count) channels are removed from this app. Exported files are not affected.")
        }
    }

    // MARK: Codeplug and radio

    private var codeplugSection: some View {
        Section("Codeplug") {
            HStack {
                Picker("Open", selection: Binding(
                    get: { model.codeplug.id },
                    set: { model.selectCodeplug($0) }
                )) {
                    ForEach(pickerCodeplugs) { plug in
                        Text("\(plug.name) (\(plug.channels.count))").tag(plug.id)
                    }
                }
                Menu {
                    Button("Rename...") {
                        renameText = model.codeplug.name
                        showRename = true
                    }
                    Button("Duplicate") { model.duplicateCodeplug() }
                    Divider()
                    Button("Delete...", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Picker("Radio", selection: Binding(
                get: { model.codeplug.target },
                set: { model.setCodeplugTarget($0) }
            )) {
                ForEach(RadioTarget.allCases) { target in
                    Label(target.rawValue, systemImage: target.icon).tag(target)
                }
            }
            HStack {
                Text("Channels")
                Spacer()
                Text("\(model.codeplug.channels.count) / \(model.codeplug.target.channelCapacity)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(model.codeplug.isOverCapacity ? Color.red : .secondary)
            }
            if !model.codeplug.channels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.codeplug.bandSummary, id: \.band) { entry in
                            Text("\(entry.band) \(entry.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        }
    }

    /// The saved codeplugs, with the open one included even before it has been saved.
    private var pickerCodeplugs: [Codeplug] {
        model.codeplugs.contains { $0.id == model.codeplug.id } ? model.codeplugs : [model.codeplug] + model.codeplugs
    }

    // MARK: Checks

    private func checksSection(_ issues: [CodeplugIssue], review: CodeplugReview) -> some View {
        let counts = CodeplugValidator.counts(issues)
        return Section {
            if issues.isEmpty {
                Label("No problems found for the \(model.codeplug.target.rawValue).", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    if counts.errors > 0 { badge("\(counts.errors) problem\(counts.errors == 1 ? "" : "s")", .red) }
                    if counts.warnings > 0 { badge("\(counts.warnings) to check", .orange) }
                    if counts.notes > 0 { badge("\(counts.notes) note\(counts.notes == 1 ? "" : "s")", .secondary) }
                }
                ForEach(issues.prefix(40)) { issue in
                    Button {
                        if let id = issue.channelID, let channel = model.codeplug.channels.first(where: { $0.id == id }) {
                            editing = channel
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(for: issue.severity))
                                .foregroundStyle(color(for: issue.severity))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                if let position = issue.position {
                                    Text("#\(position) \(name(at: position))")
                                        .font(.caption.weight(.semibold))
                                }
                                Text(issue.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if issues.count > 40 {
                    Text("Showing the first 40 of \(issues.count).").font(.caption2).foregroundStyle(.secondary)
                }
            }
            actionButtons(review)
            if let fixStatus {
                Text(fixStatus).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Checks")
        }
    }

    private func actionButtons(_ review: CodeplugReview) -> some View {
        HStack(spacing: 8) {
            Button {
                reviewSnapshot = ReviewSnapshot(review: review)
            } label: {
                Label("Review with AI", systemImage: "sparkles")
            }
            if !review.plan.isEmpty {
                Button {
                    fixPreview = FixPreview(plan: review.plan)
                } label: {
                    Label("Preview fixes…", systemImage: "wand.and.stars")
                }
            }
            if model.codeplugBeforeFix?.id == model.codeplug.id {
                Button("Undo last fix") {
                    model.undoCodeplugFix()
                    fixStatus = "Undid the last fix."
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func icon(for severity: CodeplugIssue.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for severity: CodeplugIssue.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private func name(at position: Int) -> String {
        model.codeplug.channels.indices.contains(position - 1) ? model.codeplug.channels[position - 1].name : ""
    }

    // MARK: Channels

    private func channelsSection(_ issues: [CodeplugIssue]) -> some View {
        let flagged = Dictionary(grouping: issues.compactMap { issue in issue.channelID.map { ($0, issue.severity) } }, by: \.0)
            .mapValues { $0.map(\.1).max() ?? .info }
        return Section("Channels") {
            if model.codeplug.channels.isEmpty {
                Text("Add frequencies from Browse, Search, Scanner or Trunked (swipe or context menu), import a CHIRP CSV, or add one by hand with the plus button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.codeplug.channels) { channel in
                    channelRow(channel, severity: flagged[channel.id])
                        .contentShape(Rectangle())
                        .onTapGesture { editing = channel }
                        .contextMenu {
                            Button("Edit...") { editing = channel }
                            Button("Duplicate") { model.duplicateChannel(channel) }
                            Divider()
                            Button("Remove", role: .destructive) { model.removeChannel(channel) }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                model.removeChannel(channel)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
                .onMove { source, destination in model.moveChannels(from: source, to: destination) }
            }
        }
    }

    private func channelRow(_ channel: CodeplugChannel, severity: CodeplugIssue.Severity?) -> some View {
        HStack(spacing: 10) {
            if let severity {
                Image(systemName: icon(for: severity)).foregroundStyle(color(for: severity)).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name.isEmpty ? "(no name)" : channel.name)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(channel.frequencyHz > 0 ? String(format: "%.4f", channel.frequencyHz / 1_000_000) : "no frequency")
                        .font(.caption.monospaced())
                    Text(channel.mode.rawValue).font(.caption)
                    if channel.offsetHz != 0 {
                        Text(String(format: "%+.3f", channel.offsetHz / 1_000_000)).font(.caption)
                    }
                    if channel.ctcssToneHz > 0 {
                        Text("CTCSS \(String(format: "%.1f", channel.ctcssToneHz))").font(.caption)
                    }
                    if channel.dtcsCode > 0 {
                        Text("DCS \(String(format: "%03d", channel.dtcsCode))").font(.caption)
                    }
                    if channel.talkgroupID > 0 {
                        Text("TG \(channel.talkgroupID)").font(.caption)
                    }
                    Spacer()
                    if !channel.sourceCallSign.isEmpty {
                        Text(channel.sourceCallSign).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                showImporter = true
            } label: {
                Label("Import CHIRP CSV...", systemImage: "square.and.arrow.down")
            }
            if let importStatus {
                Text(importStatus).font(.caption).foregroundStyle(.secondary)
            }

            Button {
                exportText = try? CHIRPCSVExporter.csv(for: model.codeplug.channels)
                showExportShare = exportText != nil
            } label: {
                Label("Export CHIRP CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(model.codeplug.channels.isEmpty)

            Button {
                model.sortCodeplugByFrequency()
            } label: {
                Label("Sort by frequency", systemImage: "arrow.up.arrow.down")
            }
            .disabled(model.codeplug.channels.count < 2)

            #if os(macOS)
            Button {
                writeToRadio()
            } label: {
                if writing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Write to Radio (USB cable)", systemImage: "cable.connector")
                }
            }
            .disabled(model.codeplug.channels.isEmpty || writing || !model.codeplug.target.supportsDirectWrite)
            #endif
        }
    }

    private func importCSV(_ result: Result<URL, Error>) {
        switch result {
        case let .failure(error):
            importStatus = "Could not open the file: \(error.localizedDescription)"
        case let .success(url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                importStatus = "Could not read that file as text."
                return
            }
            let imported = model.importCHIRP(csv: text)
            var message = "Imported \(imported.channels.count) channel\(imported.channels.count == 1 ? "" : "s")"
            if !imported.skipped.isEmpty {
                message += "; skipped \(imported.skipped.count): " + imported.skipped.prefix(2).joined(separator: "; ")
            }
            importStatus = message
        }
    }

    private var newPlugSheet: some View {
        NavigationStack {
            Form {
                TextField("Codeplug name", text: $newPlugName)
            }
            .navigationTitle("New Codeplug")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewPlug = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        model.newCodeplug(
                            name: newPlugName.isEmpty ? "Codeplug" : newPlugName,
                            target: model.codeplug.target
                        )
                        newPlugName = ""
                        showNewPlug = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    #if os(macOS)
    private func writeToRadio() {
        guard let devicePath = SerialTransport.availableDevices().first else {
            writeStatus = "No serial device found — connect the programming cable (e.g. /dev/cu.usbserial-*)"
            return
        }
        writing = true
        writeStatus = "Opening \(devicePath)…"
        let channels = model.codeplug.channels
        Task.detached {
            var result: CodeplugWriteResult?
            var failure: String?
            do {
                let port = try SerialTransport(path: devicePath, baudRate: 9600)
                try port.open()
                result = try await BaofengUV5R.writeChannels(channels, port: port) { phase, fraction in
                    Task { @MainActor in
                        writeStatus = "\(phase) \(Int(fraction * 100))%"
                    }
                }
                port.close()
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                writing = false
                if let result {
                    writeStatus = "Wrote \(result.channelsWritten) channels in \(String(format: "%.1f", result.durationSeconds))s"
                        + (result.errors.isEmpty ? "" : " — \(result.errors.joined(separator: "; "))")
                } else {
                    writeStatus = "Write failed: \(failure ?? "unknown error")"
                }
            }
        }
    }
    #endif
}

// MARK: - Channel editor

/// Edits one channel, checking it against the radio as you type.
private struct ChannelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CodeplugChannel
    @State private var frequencyText: String
    @State private var offsetText: String
    @State private var toneKind: ToneKind
    let target: RadioTarget
    let isNew: Bool
    let onSave: (CodeplugChannel) -> Void

    enum ToneKind: String, CaseIterable, Identifiable {
        case none = "None"
        case ctcss = "CTCSS"
        case dcs = "DCS"
        var id: String { rawValue }
    }

    init(channel: CodeplugChannel, target: RadioTarget, isNew: Bool, onSave: @escaping (CodeplugChannel) -> Void) {
        _draft = State(initialValue: channel)
        _frequencyText = State(initialValue: channel.frequencyHz > 0 ? String(format: "%.5f", channel.frequencyHz / 1_000_000) : "")
        _offsetText = State(initialValue: channel.offsetHz != 0 ? String(format: "%.3f", channel.offsetHz / 1_000_000) : "")
        _toneKind = State(initialValue: channel.dtcsCode > 0 ? .dcs : (channel.ctcssToneHz > 0 ? .ctcss : .none))
        self.target = target
        self.isNew = isNew
        self.onSave = onSave
    }

    private var assembled: CodeplugChannel {
        var channel = draft
        channel.frequencyHz = FrequencyEntry.parseMHz(frequencyText).map { $0 * 1_000_000 } ?? 0
        channel.offsetHz = (Double(offsetText.replacingOccurrences(of: ",", with: ".")) ?? 0) * 1_000_000
        switch toneKind {
        case .none:
            channel.ctcssToneHz = 0
            channel.dtcsCode = 0
        case .ctcss:
            channel.dtcsCode = 0
            if channel.ctcssToneHz <= 0 { channel.ctcssToneHz = CTCSSCatalog.tones[12] }
        case .dcs:
            channel.ctcssToneHz = 0
            if channel.dtcsCode <= 0 { channel.dtcsCode = DCSCatalog.codes[0] }
        }
        return channel
    }

    var body: some View {
        let preview = CodeplugValidator.validate(Codeplug(name: "", target: target, channels: [assembled]))
        NavigationStack {
            Form {
                Section("Channel") {
                    TextField("Name (\(target.maxNameLength) characters on this radio)", text: $draft.name)
                    TextField("Frequency (MHz)", text: $frequencyText)
                        .font(.system(.body, design: .monospaced))
                    Picker("Mode", selection: $draft.mode) {
                        ForEach(ChannelMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    TextField("Repeater offset (MHz, negative for minus)", text: $offsetText)
                        .font(.system(.body, design: .monospaced))
                }
                Section("Tone") {
                    Picker("Type", selection: $toneKind) {
                        ForEach(ToneKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                    if toneKind == .ctcss {
                        Picker("CTCSS tone", selection: $draft.ctcssToneHz) {
                            ForEach(CTCSSCatalog.tones, id: \.self) { tone in
                                Text(String(format: "%.1f Hz", tone)).tag(tone)
                            }
                        }
                    }
                    if toneKind == .dcs {
                        Picker("DCS code", selection: $draft.dtcsCode) {
                            ForEach(DCSCatalog.codes, id: \.self) { code in
                                Text(String(format: "%03d", code)).tag(code)
                            }
                        }
                    }
                }
                if target.supportsTalkgroups || draft.talkgroupID > 0 {
                    Section("Trunking") {
                        Stepper("Talkgroup \(draft.talkgroupID)", value: $draft.talkgroupID, in: 0...65_535)
                    }
                }
                Section("Other") {
                    Stepper("Power \(draft.powerWatts) W", value: $draft.powerWatts, in: 0...50)
                    TextField("Notes", text: $draft.notes)
                }
                if !preview.isEmpty {
                    Section("Checks") {
                        ForEach(preview.filter { $0.code != .duplicateChannel && $0.code != .duplicateName }) { issue in
                            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                        }
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .onChange(of: toneKind) { _, kind in
                // A picker with nothing chosen looks broken, so a newly chosen tone type starts on a common value.
                if kind == .ctcss && draft.ctcssToneHz <= 0 { draft.ctcssToneHz = 100.0 }
                if kind == .dcs && draft.dtcsCode <= 0 { draft.dtcsCode = DCSCatalog.codes[0] }
            }
            .navigationTitle(isNew ? "New Channel" : "Edit Channel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        onSave(assembled)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

// MARK: - Export sheet

struct ExportSheet: View {
    var csvText: String
    var fileName: String

    @State private var savedPath: String?

    var body: some View {
        VStack(spacing: 16) {
            if let savedPath {
                Label("Saved to \(savedPath)", systemImage: "checkmark.circle")
                    .font(.callout)
            } else {
                Text(fileName)
                    .font(.headline)
                ScrollView {
                    Text(csvText)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    ShareLink(item: csvText, preview: SharePreview(fileName)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    #if os(macOS)
                    Button("Save…") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    #endif
                }
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    #if os(macOS)
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try csvText.write(to: url, atomically: true, encoding: .utf8)
                savedPath = url.path
            } catch {
                savedPath = "save failed"
            }
        }
    }
    #endif
}

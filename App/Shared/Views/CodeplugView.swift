import SwiftUI
import SignalHiveCore

struct CodeplugView: View {
    @Environment(AppModel.self) private var model
    @State private var exportText: String?
    @State private var showExportShare = false
    @State private var writeStatus: String?
    @State private var writing = false
    @State private var showNewPlug = false
    @State private var newPlugName = ""

    var body: some View {
        List {
            targetSection
            channelsSection
            actionsSection
            if let writeStatus {
                Section {
                    Text(writeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Codeplug")
        .toolbar {
            ToolbarItem {
                Button {
                    showNewPlug = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewPlug) {
            newPlugSheet
        }
        .sheet(isPresented: $showExportShare) {
            if let exportText {
                ExportSheet(csvText: exportText, fileName: "\(model.codeplug.name)-\(model.codeplug.target.rawValue.replacingOccurrences(of: " ", with: "-")).csv")
            }
        }
    }

    private var targetSection: some View {
        Section("Radio Target") {
            Picker("Radio", selection: Binding(
                get: { model.codeplug.target },
                set: { model.codeplug.target = $0; model.persistCodeplug() }
            )) {
                ForEach(RadioTarget.allCases) { target in
                    Label(target.rawValue, systemImage: target.icon).tag(target)
                }
            }
            HStack {
                Text("Channels")
                Spacer()
                Text("\(model.codeplug.channels.count) / \(model.codeplug.target.channelCapacity)")
                    .foregroundStyle(model.codeplug.isOverCapacity ? Color.red : .secondary)
            }
        }
    }

    private var channelsSection: some View {
        Section("Channels") {
            if model.codeplug.channels.isEmpty {
                Text("Add frequencies from Browse or Search (swipe or context menu).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.codeplug.channels) { channel in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            .font(.body)
                        HStack(spacing: 8) {
                            Text(String(format: "%.4f", channel.frequencyHz / 1_000_000))
                                .font(.caption.monospaced())
                            Text(channel.mode.rawValue)
                                .font(.caption)
                            if channel.ctcssToneHz > 0 {
                                Text("CTCSS \(String(format: "%.1f", channel.ctcssToneHz))")
                                    .font(.caption)
                            }
                            if channel.dtcsCode > 0 {
                                Text("DCS \(channel.dtcsCode)")
                                    .font(.caption)
                            }
                            Spacer()
                            if !channel.sourceCallSign.isEmpty {
                                Text(channel.sourceCallSign)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            model.removeChannel(channel)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                exportText = try? CHIRPCSVExporter.csv(for: model.codeplug.channels)
                showExportShare = exportText != nil
            } label: {
                Label("Export CHIRP CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(model.codeplug.channels.isEmpty)

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

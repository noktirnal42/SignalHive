import SwiftUI
import SignalHiveCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedServices: Set<ULSService.ID> = [ULSService.lmComm.rawValue, ULSService.gmrs.rawValue]

    var body: some View {
        Form {
            databaseSection
            importSection
            aboutSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var databaseSection: some View {
        Section("Frequency Database") {
            if model.database != nil {
                HStack {
                    Text("Licenses")
                    Spacer()
                    Text("\(model.stats.licenses)").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Frequencies")
                    Spacer()
                    Text("\(model.stats.frequencies)").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Locations")
                    Spacer()
                    Text("\(model.stats.locations)").foregroundStyle(.secondary)
                }
                if model.lastImportSummary != nil {
                    Text(model.lastImportSummary!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = model.databaseError {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
    }

    private var importSection: some View {
        Section("Update ULS Data (public domain, no API key)") {
            ForEach(ULSService.allCases) { service in
                Toggle(isOn: Binding(
                    get: { selectedServices.contains(service.id) },
                    set: { on in
                        if on { selectedServices.insert(service.id) } else { selectedServices.remove(service.id) }
                    }
                )) {
                    HStack {
                        Text(service.displayName)
                        Spacer()
                        Text("~\(service.approximateSizeMB) MB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button {
                    let services = ULSService.allCases.filter { selectedServices.contains($0.id) }
                    Task { await model.importServices(services) }
                } label: {
                    if model.importActive {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Importing…")
                        }
                    } else {
                        Label("Download & Import", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.importActive || selectedServices.isEmpty)

                if model.importActive {
                    Button("Cancel") { model.cancelImport() }
                }
            }

            if let progress = model.importProgress {
                VStack(alignment: .leading) {
                    Text("\(progress.phase.rawValue.capitalized): \(progress.detail)")
                        .font(.caption)
                    ProgressView(value: min(1, max(0, progress.fraction)))
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 4) {
                Text("SignalHive")
                    .font(.headline)
                Text(DataAttribution.fccNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(DataAttribution.sources, id: \.self) { source in
                    Text("• \(source)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

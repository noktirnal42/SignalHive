import SwiftUI
import SignalHiveCore

struct FrequencyDetailView: View {
    @Environment(AppModel.self) private var model
    var uid: Int64

    @State private var detail: AppDatabase.LicenseDetail?
    @State private var loading = true
    @State private var addedToast = false

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if let detail {
                licenseSection(detail)
                if !detail.frequencies.isEmpty {
                    frequenciesSection(detail)
                }
                locationsSection(detail)
                if !detail.comments.isEmpty {
                    commentsSection(detail)
                }
            } else {
                Text("License not found")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(detail?.entity?.displayName ?? detail?.license?.callSign ?? "License")
        .task { await load() }
        .overlay(alignment: .top) {
            if addedToast {
                Text("Added to codeplug")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func licenseSection(_ detail: AppDatabase.LicenseDetail) -> some View {
        Section("License") {
            if let license = detail.license {
                row("Call Sign", license.callSign)
                row("Service", license.serviceName)
                row("Status", LicenseStatusCatalog.name(for: license.licenseStatus))
                if !license.grantDate.isEmpty { row("Granted", license.grantDate) }
                if !license.expiredDate.isEmpty { row("Expires", license.expiredDate) }
            }
            if let entity = detail.entity {
                if !entity.name.isEmpty { row("Licensee", entity.name) }
                if !entity.city.isEmpty { row("City", entity.city) }
                if !entity.state.isEmpty { row("State", entity.state) }
            }
        }
    }

    @ViewBuilder
    private func frequenciesSection(_ detail: AppDatabase.LicenseDetail) -> some View {
        Section("Frequencies (\(detail.frequencies.count))") {
            ForEach(Array(detail.frequencies.enumerated()), id: \.element.id) { _, freq in
                VStack(alignment: .leading, spacing: 2) {
                    Text(freq.displayMHz)
                        .font(.body.monospaced())
                    HStack(spacing: 8) {
                        if !freq.classStationCode.isEmpty {
                            Text("Class: \(freq.classStationCode)")
                        }
                        if !freq.powerOutput.isEmpty {
                            Text("Power: \(freq.powerOutput) W")
                        }
                        if freq.isCarrier {
                            Text("Carrier")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button {
                        addToCodeplug(freq)
                    } label: {
                        Label("Add", systemImage: "plus.memorychip")
                    }
                    .tint(.blue)
                }
                contextMenu {
                    Button {
                        addToCodeplug(freq)
                    } label: {
                        Label("Add to Codeplug", systemImage: "plus.memorychip")
                    }
                    Button {
                        model.tuneInScanner(frequencyHz: freq.frequencyHz)
                    } label: {
                        Label("Tune in Scanner", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func locationsSection(_ detail: AppDatabase.LicenseDetail) -> some View {
        if !detail.locations.isEmpty {
            Section("Locations (\(detail.locations.count))") {
                ForEach(Array(detail.locations.enumerated()), id: \.element.id) { _, loc in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([loc.city, loc.county, loc.state].filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.body)
                        if !loc.coordinateDescription.isEmpty {
                            Text(loc.coordinateDescription)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commentsSection(_ detail: AppDatabase.LicenseDetail) -> some View {
        Section("Notes") {
            ForEach(Array(detail.comments.enumerated()), id: \.offset) { _, comment in
                Text(comment.descriptionText)
                    .font(.caption)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func addToCodeplug(_ freq: ULSFrequency) {
        let name = detail?.entity?.displayName ?? freq.callSign
        let channel = CodeplugChannel(
            name: String(name.prefix(7)),
            frequencyHz: freq.frequencyHz,
            mode: freq.frequencyHz >= 118_000_000 && freq.frequencyHz <= 136_975_000 ? .am : .nfm,
            notes: "",
            sourceCallSign: freq.callSign
        )
        model.addToCodeplug(channel: channel)
        withAnimation { addedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                withAnimation { addedToast = false }
            }
        }
    }

    private func load() async {
        defer { loading = false }
        guard let database = model.database else { return }
        detail = try? await database.licenseDetail(uid: uid)
    }
}

import SwiftUI
import SignalHiveCore

struct FrequencyDetailView: View {
    @Environment(AppModel.self) private var model
    var uid: Int64

    @State private var detail: LicenseDetail?
    @State private var loading = true
    @State private var loadError: String?
    @State private var addedToast = false
    @State private var rfCoachRequest: RFCoachRequest?

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if let detail {
                licenseSection(detail)
                if !detail.frequencies.isEmpty { frequenciesSection(detail) }
                if !detail.sites.isEmpty { sitesSection(detail) }
            } else {
                ContentUnavailableView("License unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError ?? "License not found"))
            }
        }
        .navigationTitle(detail.map { $0.summary.licenseeName.isEmpty ? $0.summary.callSign : $0.summary.licenseeName } ?? "License")
        .task { await load() }
        .sheet(item: $rfCoachRequest) { request in
            RFCoachSheet(request: request)
        }
        .overlay(alignment: .top) {
            if addedToast {
                Text("Added to codeplug").font(.caption).padding(8)
                    .background(.regularMaterial, in: Capsule()).transition(.opacity)
            }
        }
    }

    private func licenseSection(_ detail: LicenseDetail) -> some View {
        Section("License") {
            row("Call Sign", detail.summary.callSign)
            row("Service", detail.summary.serviceName)
            if !detail.grantDate.isEmpty { row("Granted", detail.grantDate) }
            if !detail.expiredDate.isEmpty { row("Expires", detail.expiredDate) }
            if !detail.summary.licenseeName.isEmpty { row("Licensee", detail.summary.licenseeName) }
        }
    }

    private func frequenciesSection(_ detail: LicenseDetail) -> some View {
        Section("Frequencies (\(detail.frequencies.count))") {
            ForEach(detail.frequencies) { frequency in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(frequency.displayMHz).font(.body.monospaced())
                        ForEach(frequency.modeHints.filter { $0 != .unknown }, id: \.self) { hint in
                            Text(hint.displayName).font(.caption2).padding(.horizontal, 4)
                                .background(.quaternary, in: Capsule())
                        }
                        Spacer(minLength: 8)
                        Button {
                            explain(frequency, detail)
                        } label: {
                            Label("Explain", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        if !frequency.classStationCode.isEmpty { Text("Class \(frequency.classStationCode)") }
                        if let power = frequency.powerW { Text("\(power, specifier: "%.0f") W") }
                        if let bandwidth = frequency.bandwidthHz { Text("\(bandwidth / 1000, specifier: "%.1f") kHz") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button { explain(frequency, detail) } label: { Label("Explain with RF Coach", systemImage: "sparkles") }
                    Button { addToCodeplug(frequency, detail) } label: { Label("Add to Codeplug", systemImage: "rectangle.stack.badge.plus") }
                    Button { model.tuneInScanner(frequencyHz: frequency.frequencyHz) } label: {
                        Label("Tune in Scanner", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .swipeActions {
                    Button { addToCodeplug(frequency, detail) } label: { Label("Add", systemImage: "rectangle.stack.badge.plus") }
                        .tint(.blue)
                }
            }
        }
    }

    private func sitesSection(_ detail: LicenseDetail) -> some View {
        Section("Sites (\(detail.sites.count))") {
            ForEach(detail.sites) { site in
                VStack(alignment: .leading, spacing: 2) {
                    Text([site.city, site.countyName, site.stateCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                    if let latitude = site.latitude, let longitude = site.longitude {
                        Text(String(format: "%.4f, %.4f", latitude, longitude)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
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

    private func explain(_ frequency: FrequencyRecord, _ detail: LicenseDetail) {
        let licensee = detail.summary.licenseeName.isEmpty ? nil : detail.summary.licenseeName
        rfCoachRequest = RFCoachRequest(
            title: frequency.displayMHz,
            subtitle: [detail.summary.callSign, detail.summary.serviceName, licensee].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " · "),
            context: SignalDescriptionContext(
                frequencyHz: frequency.frequencyHz,
                mode: .suggested(frequencyHz: frequency.frequencyHz, hints: frequency.modeHints, bandwidthHz: frequency.bandwidthHz),
                bandwidthHz: frequency.bandwidthHz,
                licensee: licensee,
                callSign: detail.summary.callSign.isEmpty ? nil : detail.summary.callSign,
                serviceName: detail.summary.serviceName.isEmpty ? nil : detail.summary.serviceName,
                modeHints: frequency.modeHints
            )
        )
    }

    private func addToCodeplug(_ frequency: FrequencyRecord, _ detail: LicenseDetail) {
        let name = detail.summary.licenseeName.isEmpty ? detail.summary.callSign : detail.summary.licenseeName
        let channel = CodeplugChannel(
            name: String(name.prefix(7)),
            frequencyHz: frequency.frequencyHz,
            mode: .suggested(frequencyHz: frequency.frequencyHz, hints: frequency.modeHints, bandwidthHz: frequency.bandwidthHz),
            notes: "",
            sourceCallSign: detail.summary.callSign
        )
        model.addToCodeplug(channel: channel)
        withAnimation { addedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { addedToast = false }
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            detail = try await model.browse.detail(uid: uid)
        } catch {
            detail = nil
            loadError = error.localizedDescription
        }
    }
}

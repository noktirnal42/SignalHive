import SwiftUI
import SignalHiveCore
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AILabView: View {
    @Environment(AppModel.self) private var app
    @State private var availability = FoundationAvailabilitySnapshot.unchecked

    private let machine = LocalMachineProfile.current
    private let classifierValidation = AutoClassifierBundleValidator.validate()

    private var features: [AIFeature] {
        AIWorkbenchFeatureCatalog.features(
            classifierValidation: classifierValidation,
            foundationOnDeviceAvailable: availability.onDeviceAvailable,
            privateCloudComputeAvailable: availability.privateCloudAvailable,
            mlxRuntimeAvailable: false
        )
    }

    private var mlxModels: [MLXModelCandidate] {
        MLXModelCatalog.defaultCandidates(for: machine).map { model in
            var editable = model
            switch app.models.state(for: model.repoID) {
            case .notDownloaded: editable.downloadState = .notDownloaded
            case .downloading: editable.downloadState = .downloading
            case .installed: editable.downloadState = .installed
            case .failed: editable.downloadState = .failed
            }
            return editable
        }
    }

    var body: some View {
        ZStack {
            HiveWorkbenchBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    providerGrid
                    featureMap
                    mlxDownloadManager
                    roadmap
                }
                .padding(24)
                .frame(maxWidth: 1180, alignment: .leading)
            }
        }
        .navigationTitle("AI Lab")
        .task {
            availability = FoundationAvailabilitySnapshot.evaluate()
            await app.models.refresh(candidates: mlxModels.map(\.repoID))
        }
    }

    private var hero: some View {
        HiveInstrumentPanel(status: "native intelligence") {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        HiveStatusBadge("Core ML", tint: HiveInk.mint)
                        HiveStatusBadge("Foundation", tint: HiveInk.cyan)
                        HiveStatusBadge("MLX", tint: HiveInk.amber)
                    }
                    Text("AI Lab")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Signal-aware intelligence for identification, explanations, session reports, codeplug checks, and local radio assistants.")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                    HiveSpectrumRibbon(samples: aiSamples, tint: HiveInk.mint)
                        .frame(height: 76)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HiveSignalMeter(
                    value: Double(features.filter { $0.status == .available }.count) / Double(max(features.count, 1)),
                    label: "AI",
                    unit: "\(features.filter { $0.status == .available }.count)/\(features.count)",
                    tint: HiveInk.mint
                )
                .frame(width: 250, height: 178)
            }
        }
    }

    private var providerGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 10)], spacing: 10) {
            providerTile(
                title: "Core ML signal ID",
                value: classifierValidation.passed ? "Ready" : "Model needed",
                detail: classifierValidation.passed
                    ? "AutoClassifier package and evidence are present."
                    : classifierValidation.issues.joined(separator: ", "),
                icon: "waveform.badge.magnifyingglass",
                tint: classifierValidation.passed ? HiveInk.mint : HiveInk.amber
            )
            providerTile(
                title: "On-device Foundation",
                value: availability.onDeviceLabel,
                detail: availability.onDeviceDetail,
                icon: "brain.head.profile",
                tint: availability.onDeviceAvailable == true ? HiveInk.mint : HiveInk.cyan
            )
            providerTile(
                title: "Private Cloud Compute",
                value: availability.privateCloudLabel,
                detail: availability.privateCloudDetail,
                icon: "lock.icloud",
                tint: availability.privateCloudAvailable == true ? HiveInk.mint : HiveInk.amber
            )
            providerTile(
                title: "MLX local profile",
                value: machine.displayMemory,
                detail: "\(machine.chipName). Default to 1B/3B 4-bit models; avoid 12B-class models here.",
                icon: "memorychip",
                tint: HiveInk.cyan
            )
        }
    }

    private func providerTile(title: String, value: String, detail: String, icon: String, tint: Color) -> some View {
        HiveInstrumentPanel(status: value) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text(detail.isEmpty ? "No detail reported." : detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(minHeight: 126, alignment: .top)
    }

    private var featureMap: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Feature Map")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 10)], spacing: 10) {
                ForEach(features) { feature in
                    featureTile(feature)
                }
            }
        }
    }

    private func featureTile(_ feature: AIFeature) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: feature.provider))
                    .foregroundStyle(color(for: feature.status))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text("\(feature.provider.displayName) / \(feature.status.displayName)")
                        .font(.caption)
                        .foregroundStyle(color(for: feature.status))
                }
                Spacer(minLength: 0)
            }
            Text(feature.detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
            Text(feature.privacy)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.44))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                ioLine("IN", feature.inputs)
                ioLine("OUT", feature.outputs)
            }

            HStack(spacing: 6) {
                ForEach(feature.useCases.prefix(3), id: \.self) { useCase in
                    Text(useCase)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }

            if !feature.nextMilestone.isEmpty {
                Text("Next: \(feature.nextMilestone)")
                    .font(.caption2)
                    .foregroundStyle(HiveInk.amber.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 276, alignment: .topLeading)
        .background(HiveInk.panel.opacity(0.80), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color(for: feature.status).opacity(0.24), lineWidth: 1)
        }
    }

    private func ioLine(_ label: String, _ values: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(HiveInk.cyan.opacity(0.82))
                .frame(width: 24, alignment: .leading)
            Text(values.isEmpty ? "TBD" : values.prefix(4).joined(separator: " / "))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.50))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mlxDownloadManager: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeading("MLX Download Manager")
                Spacer()
                HiveStatusBadge("\(machine.chipName) / \(machine.displayMemory)", tint: HiveInk.cyan)
            }
            Text("Models are fetched from Hugging Face into SignalHive's Application Support folder and checked against their published checksums. A cancelled or interrupted download resumes at the file it stopped on. No inference runtime uses them yet.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 10)], spacing: 10) {
                ForEach(mlxModels) { model in
                    modelTile(model)
                }
            }
        }
    }

    private func modelTile(_ model: MLXModelCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox.and.arrow.down")
                    .foregroundStyle(color(for: model.compatibility))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text(model.repoID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HiveStatusBadge(model.compatibility.displayName, tint: color(for: model.compatibility))
            }

            Text(model.compatibilityReason)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                metadata("\(String(format: "%.1f", model.parameterCountB))B")
                metadata(model.quantization)
                metadata("~\(String(format: "%.1f", model.approximateDownloadGB)) GB")
                metadata(model.modality)
            }

            Text(model.recommendedUse)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)

            downloadControls(for: model)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 232, alignment: .topLeading)
        .background(HiveInk.panel.opacity(0.80), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color(for: model.compatibility).opacity(0.24), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func downloadControls(for model: MLXModelCandidate) -> some View {
        let state = app.models.state(for: model.repoID)
        let partial = app.models.partialBytes[model.repoID] ?? 0
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .notDownloaded, .failed:
                if case let .failed(reason) = state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button {
                        app.models.download(model.repoID)
                    } label: {
                        Label(partial > 0 ? "Resume" : "Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(color(for: model.compatibility))
                    .disabled(model.compatibility == .notRecommended)
                    hubLink(model)
                    Spacer()
                    Text(partial > 0 ? "\(ByteCountFormatter.string(fromByteCount: partial, countStyle: .file)) already here" : model.downloadState.displayName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.54))
                }
            case let .downloading(progress):
                ProgressView(value: progress.fraction)
                    .tint(HiveInk.cyan)
                HStack {
                    Text(progressText(progress))
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") { app.models.cancel(model.repoID) }
                        .buttonStyle(.bordered)
                }
            case let .installed(record):
                HStack {
                    Label("Installed, \(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    hubLink(model)
                    Spacer()
                    Button("Remove", role: .destructive) { Task { await app.models.remove(model.repoID) } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func hubLink(_ model: MLXModelCandidate) -> some View {
        Link(destination: URL(string: "https://huggingface.co/\(model.repoID)")!) {
            Label("Hub", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.bordered)
        .tint(HiveInk.cyan)
    }

    private func progressText(_ progress: ModelInstallProgress) -> String {
        switch progress.phase {
        case .listing: return "Listing files…"
        case .finishing: return "Finishing…"
        case .downloading:
            let done = ByteCountFormatter.string(fromByteCount: progress.bytesDone, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.bytesTotal, countStyle: .file)
            return "\(done) of \(total) · file \(progress.fileIndex)/\(progress.fileCount)"
        }
    }

    private var roadmap: some View {
        HiveInstrumentPanel("Implementation Path", status: "truthful gates") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                roadmapStep("1", "Finish Core ML classifier assets", "Bundle or download the real AutoClassify_v2.mlpackage and show accuracy/latency evidence in-app.")
                roadmapStep("2", "Turn RF coach into actions", "Attach Foundation summaries to Browse, Scanner, Trunked, ADS-B/UAT, AIS, and Codeplug views.")
                roadmapStep("3", "Wire PCC only when entitled", "Use PCC for long reports after entitlement, network, quota, and availability checks pass.")
                roadmapStep("4", "Connect a local inference runtime", "Model downloads work: files are listed from Hugging Face, fetched, checked against their published SHA-256 and kept in Application Support. Nothing runs them yet; an MLX inference adapter is the next step.")
            }
        }
    }

    private func roadmapStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(HiveInk.amber)
                .frame(width: 30, height: 30)
                .background(HiveInk.amber.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadata(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.64))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.white.opacity(0.07), in: Capsule())
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func icon(for provider: AIProviderKind) -> String {
        switch provider {
        case .coreML: return "waveform.badge.magnifyingglass"
        case .foundationOnDevice: return "brain.head.profile"
        case .foundationPrivateCloud: return "lock.icloud"
        case .mlxLocal: return "memorychip"
        case .rulesEngine: return "checklist"
        }
    }

    private func color(for status: AIFeatureStatus) -> Color {
        switch status {
        case .available: return HiveInk.mint
        case .readyWhenAvailable: return HiveInk.cyan
        case .requiresEntitlement: return HiveInk.amber
        case .needsModel: return HiveInk.copper
        case .planned: return .secondary
        case .notRecommended: return .red
        }
    }

    private func color(for tier: MLXCompatibilityTier) -> Color {
        switch tier {
        case .worksWell: return HiveInk.mint
        case .works: return HiveInk.cyan
        case .heavy: return HiveInk.amber
        case .notRecommended: return .red
        case .unknown: return .secondary
        }
    }

    private var aiSamples: [Double] {
        [0.18, 0.22, 0.41, 0.24, 0.31, 0.76, 0.29, 0.20, 0.54, 0.33, 0.27, 0.91, 0.36, 0.24, 0.42, 0.67, 0.30, 0.21, 0.58, 0.26, 0.19, 0.48, 0.82, 0.37]
    }
}

private struct FoundationAvailabilitySnapshot: Sendable, Equatable {
    var onDeviceAvailable: Bool?
    var onDeviceLabel: String
    var onDeviceDetail: String
    var privateCloudAvailable: Bool?
    var privateCloudLabel: String
    var privateCloudDetail: String

    static let unchecked = FoundationAvailabilitySnapshot(
        onDeviceAvailable: nil,
        onDeviceLabel: "Checking",
        onDeviceDetail: "Waiting for the Foundation Models availability probe.",
        privateCloudAvailable: nil,
        privateCloudLabel: "Checking",
        privateCloudDetail: "Waiting for the Private Cloud Compute availability probe."
    )

    static func evaluate() -> FoundationAvailabilitySnapshot {
        #if canImport(FoundationModels)
        var onDeviceAvailable: Bool?
        var onDeviceLabel = "Unavailable"
        var onDeviceDetail = "Foundation Models framework imported, but this OS/device did not report readiness."
        var privateCloudAvailable: Bool?
        var privateCloudLabel = "Entitlement gated"
        var privateCloudDetail = "PCC requires supported OS, Apple Intelligence support, network, quota, and the managed entitlement."

        if #available(macOS 26.0, iOS 26.0, *) {
            let model = SystemLanguageModel.default
            onDeviceAvailable = model.isAvailable
            onDeviceLabel = model.isAvailable ? "Available" : "Unavailable"
            onDeviceDetail = String(describing: model.availability)
        }

        // Private Cloud Compute arrived with the 27 SDKs (Swift 6.4); older toolchains, such as the CI runner's, do not
        // know the type, so the probe is compiled only where it exists.
        #if compiler(>=6.4)
        if #available(macOS 27.0, iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            privateCloudAvailable = model.isAvailable
            privateCloudLabel = model.isAvailable ? "Available" : "Entitlement gated"
            privateCloudDetail = String(describing: model.availability)
        }
        #endif

        return FoundationAvailabilitySnapshot(
            onDeviceAvailable: onDeviceAvailable,
            onDeviceLabel: onDeviceLabel,
            onDeviceDetail: onDeviceDetail,
            privateCloudAvailable: privateCloudAvailable,
            privateCloudLabel: privateCloudLabel,
            privateCloudDetail: privateCloudDetail
        )
        #else
        return FoundationAvailabilitySnapshot(
            onDeviceAvailable: false,
            onDeviceLabel: "Unavailable",
            onDeviceDetail: "Foundation Models framework is not available in this SDK.",
            privateCloudAvailable: false,
            privateCloudLabel: "Unavailable",
            privateCloudDetail: "Private Cloud Compute model APIs are not available in this SDK."
        )
        #endif
    }
}

import SwiftUI
import SignalHiveCore

/// Answers an `AIRequest` through `AIRouter`: SignalHive Rules always, the on-device model when it is available, Private
/// Cloud Compute only after the operator picks it and presses the button. Every answer says who gave it and from what.
struct AIAnswerSheet: View {
    var navigationTitle: String
    var title: String
    var subtitle = ""
    var note: String?
    var makeRequest: (AIProviderKind?) -> AIRequest
    /// A new identity restarts the run (a new request, not just a new provider choice).
    var identity: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var choice = ProviderChoice.automatic
    /// Raised by the "Ask Private Cloud Compute" button; the cloud is never called without it.
    @State private var cloudToken = 0
    @State private var partial: (text: String, provider: AIProviderKind)?
    @State private var answer: AIAnswer?
    @State private var failure: String?
    @State private var running = false
    /// The exact text a Private Cloud Compute request would send, shown before the operator agrees.
    @State private var outgoing: String?

    private let router = AIRouter(providers: [FoundationOnDeviceProvider(), PrivateCloudProvider()])

    enum ProviderChoice: String, CaseIterable, Identifiable {
        case automatic = "Automatic"
        case onDevice = "On-device"
        case rules = "Rules only"
        case cloud = "Private Cloud"

        var id: String { rawValue }

        var preferred: AIProviderKind? {
            switch self {
            case .automatic: return nil
            case .onDevice: return .foundationOnDevice
            case .rules: return .rulesEngine
            case .cloud: return .foundationPrivateCloud
            }
        }
    }

    private struct RunKey: Equatable {
        var request: UUID
        var choice: ProviderChoice
        var cloudToken: Int
    }

    private var waitingForCloudConsent: Bool { choice == .cloud && cloudToken == 0 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("Answer with", selection: $choice) {
                    ForEach(ProviderChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: choice) { _, _ in cloudToken = 0 }

                if waitingForCloudConsent {
                    cloudConsent
                } else if let answer {
                    answerPanel(answer)
                } else if let partial {
                    streamingPanel(partial)
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Working on it.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                }

                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(minWidth: 560, minHeight: 460)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: RunKey(request: identity, choice: choice, cloudToken: cloudToken)) { await explain() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note, !note.isEmpty {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func providerLabel(_ provider: AIProviderKind) -> some View {
        let (symbol, place, tint): (String, String, Color) = switch provider {
        case .rulesEngine: ("checkmark.seal", "Local, deterministic", .green)
        case .foundationOnDevice, .mlxLocal, .coreML: ("cpu", "On this Mac", .green)
        case .foundationPrivateCloud: ("lock.icloud", "Answered in Apple's Private Cloud Compute", .orange)
        }
        return HStack {
            Label(provider.displayName, systemImage: symbol)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(tint)
            Spacer()
            Text(place)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Panels

    private var cloudConsent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Private Cloud Compute", systemImage: "lock.icloud")
                .font(.headline)
            Text("This sends exactly the text below to Apple's Private Cloud Compute to answer. Nothing is sent until you press the button.")
                .fixedSize(horizontal: false, vertical: true)
            if let outgoing {
                ScrollView {
                    Text(outgoing)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 170)
                .padding(8)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView().controlSize(.small)
            }
            Button {
                cloudToken += 1
            } label: {
                Label("Ask Private Cloud Compute", systemImage: "paperplane")
            }
            .buttonStyle(.borderedProminent)
            .disabled(outgoing == nil)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func streamingPanel(_ partial: (text: String, provider: AIProviderKind)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            providerLabel(partial.provider)
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(partial.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func answerPanel(_ answer: AIAnswer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            providerLabel(answer.provider)
            Label(answer.confidence, systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text(answer.summary)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let next = answer.recommendation {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recommended next step")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(next)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !answer.facts.isEmpty {
                DisclosureGroup("Facts this answer was held to (SignalHive Rules)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(answer.facts, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }
                    .padding(.top, 4)
                }
                .font(.caption.weight(.semibold))
            }

            ForEach(answer.notes, id: \.self) { note in
                Label(note, systemImage: "arrow.uturn.right")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack(alignment: .top) {
                inputsList(answer.inputs)
                Spacer(minLength: 12)
                Text(String(format: "%.1f s", answer.latency))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func inputsList(_ inputs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Inputs used")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(inputs.joined(separator: " · "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Running

    private func explain() async {
        answer = nil
        partial = nil
        failure = nil
        outgoing = nil
        guard !waitingForCloudConsent else {
            outgoing = try? await router.outgoingText(for: makeRequest(choice.preferred))
            return
        }
        running = true
        defer { running = false }
        do {
            for try await chunk in router.answer(makeRequest(choice.preferred)) {
                switch chunk {
                case let .partial(text, provider): partial = (text, provider)
                case let .done(final):
                    answer = final
                    partial = nil
                }
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

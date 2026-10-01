import SwiftUI
import SignalHiveCore

struct RFCoachRequest: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var subtitle: String
    var context: SignalDescriptionContext
    var operatorNote: String?

    init(
        title: String,
        subtitle: String = "",
        context: SignalDescriptionContext,
        operatorNote: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.context = context
        self.operatorNote = operatorNote
    }
}

struct RFCoachSheet: View {
    var request: RFCoachRequest

    @Environment(\.dismiss) private var dismiss
    @State private var result: SignalDescription?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                header

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("SignalHive Rules is reading the radio context.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                } else if let result {
                    resultPanel(result)
                }

                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(minWidth: 520, minHeight: 360)
            .navigationTitle("RF Coach")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: request.id) { await explain() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("SignalHive Rules", systemImage: "checkmark.seal")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Text("Local, deterministic")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Text(request.title)
                .font(.title2.weight(.semibold))
            if !request.subtitle.isEmpty {
                Text(request.subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = request.operatorNote, !note.isEmpty {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resultPanel(_ result: SignalDescription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(result.confidence, systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text(result.explanation)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Recommended next step")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(result.recommendation)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func explain() async {
        isLoading = true
        result = await SignalDescriptionEngine().describe(context: request.context)
        isLoading = false
    }
}

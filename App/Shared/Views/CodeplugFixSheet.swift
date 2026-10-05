import SwiftUI
import SignalHiveCore

/// The fixes the app can make on its own, as before-and-after lines. Nothing changes until Apply is pressed.
struct CodeplugFixSheet: View {
    var plan: CodeplugFixPlan
    var codeplugName: String
    var apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Proposed fixes")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("\(plan.changes.count) change\(plan.changes.count == 1 ? "" : "s") to \"\(codeplugName)\". Nothing changes until you press Apply, and you can undo it afterwards.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(plan.changes) { change in
                Label(change.summary, systemImage: symbol(for: change.kind))
                    .foregroundStyle(tint(for: change.kind))
                    .textSelection(.enabled)
            }
            .listStyle(.inset)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply \(plan.changes.count) change\(plan.changes.count == 1 ? "" : "s")") {
                    apply()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 380)
        #endif
    }

    private func symbol(for kind: CodeplugChange.Kind) -> String {
        switch kind {
        case .renamed: return "pencil"
        case .removedDuplicate, .droppedOverCapacity: return "minus.circle"
        }
    }

    private func tint(for kind: CodeplugChange.Kind) -> Color {
        switch kind {
        case .renamed: return .primary
        case .removedDuplicate: return .orange
        case .droppedOverCapacity: return .red
        }
    }
}

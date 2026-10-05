import SwiftUI
import SignalHiveCore

/// What a Workshop tile can present: the fix for a missing prerequisite, or the explanation for something not connected.
enum WorkshopSheet: Identifiable {
    case getData
    case usbHelp
    case install(String)
    case learn(title: String, text: String)

    var id: String {
        switch self {
        case .getData: return "get-data"
        case .usbHelp: return "usb-help"
        case let .install(name): return "install-\(name)"
        case let .learn(title, _): return "learn-\(title)"
        }
    }
}

/// A short, honest explanation with optional steps and buttons.
struct WorkshopInfoSheet: View {
    struct Step: Identifiable {
        var id = UUID()
        var text: String
        var isCommand = false
    }

    struct SheetAction: Identifiable {
        var id: String { title }
        var title: String
        var run: () -> Void
    }

    var title: String
    var message: String
    var steps: [Step] = []
    var actions: [SheetAction] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if step.isCommand {
                                Text(step.text)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(step.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                ForEach(actions) { action in
                    Button(action.title) {
                        action.run()
                        dismiss()
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 240)
        #endif
    }
}

extension WorkshopInfoSheet {
    static func usbHelp(checkAgain: @escaping () -> Void, addNetworkSource: @escaping () -> Void) -> WorkshopInfoSheet {
        WorkshopInfoSheet(
            title: "Connect an RTL-SDR",
            message: "SignalHive talks to an RTL-SDR directly over USB, so there is no driver to install.",
            steps: [
                Step(text: "Plug the dongle into a USB port and attach an antenna."),
                Step(text: "Quit any other program that uses it (SDR++, GQRX, rtl_tcp, rtl_433). Only one program can hold the dongle at a time."),
                Step(text: "Press Check again."),
                Step(text: "No dongle on this Mac? Add an rtl_tcp server on your network as a source instead."),
            ],
            actions: [
                SheetAction(title: "Check again", run: checkAgain),
                SheetAction(title: "Add network source", run: addNetworkSource),
            ])
    }

    static func install(_ tool: String, checkAgain: @escaping () -> Void) -> WorkshopInfoSheet {
        if tool == "libhackrf" {
            return WorkshopInfoSheet(
                title: "HackRF support",
                message: "A HackRF One receives through libhackrf, which SignalHive does not bundle.",
                steps: [
                    Step(text: "brew install hackrf", isCommand: true),
                    Step(text: "Plug in the HackRF One and press Check again."),
                ],
                actions: [SheetAction(title: "Check again", run: checkAgain)])
        }
        return WorkshopInfoSheet(
            title: "Install \(tool)",
            message: "SignalHive looks for \(tool) on this Mac and does not bundle it.",
            steps: [Step(text: "Install \(tool), then press Check again.")],
            actions: [SheetAction(title: "Check again", run: checkAgain)])
    }
}

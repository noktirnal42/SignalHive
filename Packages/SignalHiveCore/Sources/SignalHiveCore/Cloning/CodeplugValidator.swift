import Foundation

public struct CodeplugIssue: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case info = 0
        case warning = 1
        case error = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .info: return "Note"
            case .warning: return "Check"
            case .error: return "Problem"
            }
        }
    }

    public enum Code: String, Sendable {
        case overCapacity
        case emptyName
        case nameTooLong
        case noFrequency
        case outOfRange
        case unsupportedMode
        case duplicateChannel
        case duplicateName
        case nonStandardTone
        case toneConflict
        case hugeOffset
        case talkgroupOnly
    }

    public var code: Code
    public var severity: Severity
    /// The channel it is about; nil for problems with the whole codeplug.
    public var channelID: UUID?
    /// 1-based position, for showing "#3".
    public var position: Int?
    public var message: String

    public var id: String { code.rawValue + "|" + (channelID?.uuidString ?? "plug") }
}

/// Deterministic checks of a codeplug against the radio it is for: the mistakes that waste an evening at the bench
/// (too many channels, names the radio cannot show, frequencies it cannot tune, modes it cannot decode, duplicate
/// entries, odd tones). These checks are the first, and always available, half of the "codeplug assistant"; wording them
/// with a language model comes on top of them, never instead.
public enum CodeplugValidator {
    public static func validate(_ codeplug: Codeplug) -> [CodeplugIssue] {
        let target = codeplug.target
        var issues: [CodeplugIssue] = []

        if codeplug.channels.count > target.channelCapacity {
            let extra = codeplug.channels.count - target.channelCapacity
            issues.append(CodeplugIssue(
                code: .overCapacity, severity: .error, channelID: nil, position: nil,
                message: "\(codeplug.channels.count) channels, but the \(target.rawValue) holds \(target.channelCapacity). The last \(extra) would not be written."))
        }

        var firstWithKey: [String: Int] = [:]
        var firstWithName: [String: Int] = [:]

        for (index, channel) in codeplug.channels.enumerated() {
            let position = index + 1
            func add(_ code: CodeplugIssue.Code, _ severity: CodeplugIssue.Severity, _ message: String) {
                issues.append(CodeplugIssue(code: code, severity: severity, channelID: channel.id, position: position, message: message))
            }

            // Name
            let name = channel.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                add(.emptyName, .warning, "No name. The radio will show only the frequency.")
            } else if name.count > target.maxNameLength {
                let cut = String(name.prefix(target.maxNameLength))
                add(.nameTooLong, .warning, "\"\(name)\" is longer than the \(target.maxNameLength) characters the radio shows; it would be cut to \"\(cut)\".")
            }

            // Frequency
            if channel.frequencyHz <= 0 {
                if channel.talkgroupID > 0 && target.supportsTalkgroups {
                    add(.talkgroupOnly, .info, "A talkgroup channel: the trunked system's frequencies are programmed on the scanner, not here.")
                } else if channel.talkgroupID > 0 {
                    add(.noFrequency, .error, "A talkgroup has no frequency of its own, and the \(target.rawValue) cannot follow trunked systems. Add the system's voice or control frequency instead.")
                } else {
                    add(.noFrequency, .error, "No frequency.")
                }
            } else if !target.covers(channel.frequencyHz) {
                add(.outOfRange, .warning, String(format: "%.4f MHz is outside the bands the %@ is documented to cover.", channel.frequencyHz / 1_000_000, target.rawValue))
            }

            // Mode
            if !target.supportedModes.contains(channel.mode) {
                add(.unsupportedMode, .error, "The \(target.rawValue) cannot use \(channel.mode.rawValue).")
            }

            // Tones
            if channel.ctcssToneHz > 0 && !CTCSSCatalog.isStandard(channel.ctcssToneHz) {
                add(.nonStandardTone, .warning, String(format: "%.1f Hz is not one of the standard CTCSS tones.", channel.ctcssToneHz))
            }
            if channel.dtcsCode != 0 && !DCSCatalog.isStandard(channel.dtcsCode) {
                add(.nonStandardTone, .warning, String(format: "DCS %03d is not a standard code.", channel.dtcsCode))
            }
            if channel.ctcssToneHz > 0 && channel.dtcsCode != 0 {
                add(.toneConflict, .warning, "Both a CTCSS tone and a DCS code are set; a radio uses only one.")
            }

            // Offset
            if abs(channel.offsetHz) > 10_000_000 {
                add(.hugeOffset, .warning, String(format: "A repeater offset of %.3f MHz is unusually large.", channel.offsetHz / 1_000_000))
            }

            // Duplicates
            if channel.frequencyHz > 0 {
                let key = String(format: "%.0f|%.0f|%@|%.1f|%d", channel.frequencyHz, channel.offsetHz, channel.mode.rawValue,
                                 channel.ctcssToneHz, channel.dtcsCode)
                if let first = firstWithKey[key] {
                    add(.duplicateChannel, .warning, "Same frequency, offset, mode and tone as #\(first).")
                } else {
                    firstWithKey[key] = position
                }
            }
            if !name.isEmpty {
                let key = name.lowercased()
                if let first = firstWithName[key] {
                    add(.duplicateName, .info, "The name \"\(name)\" is also used by #\(first).")
                } else {
                    firstWithName[key] = position
                }
            }
        }

        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return ($0.position ?? 0) < ($1.position ?? 0)
        }
    }

    public static func counts(_ issues: [CodeplugIssue]) -> (errors: Int, warnings: Int, notes: Int) {
        (issues.filter { $0.severity == .error }.count, issues.filter { $0.severity == .warning }.count,
         issues.filter { $0.severity == .info }.count)
    }
}

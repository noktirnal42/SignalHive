import Foundation

// A codeplug review: the validator's findings, the fixes the app can make on its own, and wording for both. The findings
// and the fixes are deterministic; a language model may explain them but never edits the codeplug. Fixes are previewed as
// before-and-after lines and only applied when the operator says so.

/// One thing a fix would do to one channel.
public struct CodeplugChange: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case renamed(from: String, to: String, reason: String)
        /// Removed because it repeats the channel at this (1-based) position.
        case removedDuplicate(of: Int)
        case droppedOverCapacity
    }

    public var channelID: UUID
    /// 1-based position in the codeplug as it is now.
    public var position: Int
    public var channelName: String
    public var kind: Kind
    public var summary: String

    public var id: UUID { channelID }
}

/// What the app's own fixes would do to a codeplug, worked out without changing it: repeats removed, names fitted to the
/// radio, channels beyond its capacity dropped. `fixed` is exactly what applying the existing fixes in that order gives.
public struct CodeplugFixPlan: Equatable, Sendable {
    public var changes: [CodeplugChange]
    public var fixed: Codeplug

    public var isEmpty: Bool { changes.isEmpty }

    public static func make(for codeplug: Codeplug) -> CodeplugFixPlan {
        let original = codeplug.channels

        var firstWithKey: [String: Int] = [:]
        var repeats: [UUID: Int] = [:]
        for (index, channel) in original.enumerated() {
            guard let key = channel.repeatKey else { continue }
            if let first = firstWithKey[key] { repeats[channel.id] = first } else { firstWithKey[key] = index + 1 }
        }

        var fixed = codeplug
        fixed.removeDuplicates()
        fixed.fitToRadio()
        let after = Dictionary(uniqueKeysWithValues: fixed.channels.map { ($0.id, $0) })

        var changes: [CodeplugChange] = []
        for (index, channel) in original.enumerated() {
            let position = index + 1
            let label = displayName(channel.name)
            func add(_ kind: CodeplugChange.Kind, _ summary: String) {
                changes.append(CodeplugChange(channelID: channel.id, position: position, channelName: channel.name,
                                              kind: kind, summary: summary))
            }
            if let first = repeats[channel.id] {
                add(.removedDuplicate(of: first), "#\(position) \(label) removed: a repeat of #\(first) (\(displayName(original[first - 1].name)))")
            } else if let kept = after[channel.id] {
                guard kept.name != channel.name else { continue }
                let reason = renameReason(from: channel.name, to: kept.name, limit: codeplug.target.maxNameLength)
                add(.renamed(from: channel.name, to: kept.name, reason: reason),
                    "#\(position) \(label) → \(displayName(kept.name)) (\(reason))")
            } else {
                add(.droppedOverCapacity,
                    "#\(position) \(label) dropped: the \(codeplug.target.rawValue) holds \(codeplug.target.channelCapacity) channels")
            }
        }
        return CodeplugFixPlan(changes: changes, fixed: fixed)
    }

    /// The fixed codeplug, but only if `codeplug` is still what this plan was previewed against: the plan is made again and
    /// must list exactly the same changes. nil when something changed since the preview, or when there is nothing to do.
    public func applying(to codeplug: Codeplug) -> Codeplug? {
        let current = Self.make(for: codeplug)
        guard !current.isEmpty, current.changes == changes else { return nil }
        return current.fixed
    }

    private static func displayName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "(no name)" : name
    }

    private static func renameReason(from original: String, to fitted: String, limit: Int) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        if trimmed.count > limit { return "cut to \(limit) characters" }
        if original.unicodeScalars.contains(where: { !$0.isASCII || $0.value < 32 }) { return "plain ASCII only" }
        if trimmed == fitted { return "extra spaces trimmed" }
        return "kept distinct"
    }
}

public struct CodeplugReview: Equatable, Sendable {
    public var codeplugName: String
    public var target: RadioTarget
    public var channelCount: Int
    public var issues: [CodeplugIssue]
    public var plan: CodeplugFixPlan
    public private(set) var headline: String
    /// The findings, the proposed fixes and what is left for the operator, one fact per line.
    public private(set) var lines: [String]
    /// What to do next, in one sentence; nil when there is nothing to do.
    public private(set) var recommendation: String?

    public var counts: (errors: Int, warnings: Int, notes: Int) { CodeplugValidator.counts(issues) }

    /// Findings the app can fix itself; the rest need a decision the app cannot make for the operator.
    private static let fixable: Set<CodeplugIssue.Code> = [.nameTooLong, .overCapacity, .duplicateChannel, .duplicateName]
    private static let listLimit = 12

    public static func make(for codeplug: Codeplug) -> CodeplugReview {
        let issues = CodeplugValidator.validate(codeplug)
        let plan = CodeplugFixPlan.make(for: codeplug)
        let target = codeplug.target
        let count = codeplug.channels.count
        let counts = CodeplugValidator.counts(issues)

        var review = CodeplugReview(codeplugName: codeplug.name, target: target, channelCount: count, issues: issues, plan: plan,
                                    headline: "", lines: [], recommendation: nil)
        guard count > 0 else {
            review.headline = "The codeplug is empty."
            review.lines = ["Add channels from Browse, Search, Scanner or Trunked, then review it."]
            return review
        }

        let subject = "\(count) channel\(count == 1 ? "" : "s") for the \(target.rawValue)"
        if issues.isEmpty {
            review.headline = "\(subject): no problems found."
        } else {
            var parts: [String] = []
            if counts.errors > 0 { parts.append("\(counts.errors) problem\(counts.errors == 1 ? "" : "s")") }
            if counts.warnings > 0 { parts.append("\(counts.warnings) to check") }
            if counts.notes > 0 { parts.append("\(counts.notes) note\(counts.notes == 1 ? "" : "s")") }
            review.headline = "\(subject): \(parts.joined(separator: ", "))."
        }

        var lines: [String] = []
        for issue in issues.prefix(listLimit) {
            var subjectText = ""
            if let position = issue.position {
                let name = codeplug.channels.indices.contains(position - 1) ? codeplug.channels[position - 1].name : ""
                subjectText = " #\(position) \(name.trimmingCharacters(in: .whitespaces).isEmpty ? "(no name)" : name)"
            }
            lines.append("\(issue.severity.label)\(subjectText): \(issue.message)")
        }
        if issues.count > listLimit {
            let more = issues.count - listLimit
            lines.append("…and \(more) more finding\(more == 1 ? "" : "s").")
        }

        if !plan.isEmpty {
            lines.append("Proposed fixes (nothing has been changed):")
            lines += plan.changes.prefix(listLimit).map(\.summary)
            if plan.changes.count > listLimit {
                let more = plan.changes.count - listLimit
                lines.append("…and \(more) more change\(more == 1 ? "" : "s").")
            }
        }

        let decisions = issues.filter { !fixable.contains($0.code) }.count
        if decisions > 0 {
            lines.append("\(decisions) finding\(decisions == 1 ? " needs" : "s need") your decision: the app cannot pick a frequency, tone or mode for you.")
        }
        review.lines = lines

        switch (plan.isEmpty, decisions) {
        case (true, 0):
            review.recommendation = nil
        case (false, 0):
            review.recommendation = "Preview the proposed fixes and apply them if they look right."
        case (false, let n):
            review.recommendation = "Preview the proposed fixes and apply them if they look right, then settle the \(n) finding\(n == 1 ? "" : "s") that \(n == 1 ? "needs" : "need") your decision by hand."
        case (true, let n):
            review.recommendation = "Settle the \(n) finding\(n == 1 ? "" : "s") by hand; the app has no safe automatic fix for \(n == 1 ? "it" : "them")."
        }
        return review
    }
}

import Testing
import Foundation
@testable import SignalHiveCore

private func channel(_ name: String, _ mhz: Double, tone: Double = 0, talkgroup: Int = 0) -> CodeplugChannel {
    CodeplugChannel(name: name, frequencyHz: mhz * 1_000_000, ctcssToneHz: tone, talkgroupID: talkgroup)
}

private func plug(_ channels: [CodeplugChannel], target: RadioTarget = .baofengUV5R) -> Codeplug {
    Codeplug(name: "Test", target: target, channels: channels)
}

/// What the existing one-press fixes do, in the order the plan applies them.
private func appliedTheExistingWay(_ codeplug: Codeplug) -> Codeplug {
    var copy = codeplug
    copy.removeDuplicates()
    copy.fitToRadio()
    return copy
}

// MARK: - Fix plan

struct CodeplugFixPlanTests {
    @Test func aCleanCodeplugNeedsNoFixes() {
        let codeplug = plug([channel("SHERIFF", 155.475), channel("FIRE", 154.28)])
        let plan = CodeplugFixPlan.make(for: codeplug)

        #expect(plan.isEmpty)
        #expect(plan.fixed.channels == codeplug.channels)
    }

    @Test func renamesAreShownAsBeforeAndAfterWithTheReason() {
        let codeplug = plug([channel("POLICE DEPT", 155.1), channel("POLICE DIV", 155.2), channel("Fire", 154.3), channel("Ünïcode", 154.4)])
        let plan = CodeplugFixPlan.make(for: codeplug)

        #expect(plan.fixed.channels.map(\.name) == ["POLICE", "POLICE2", "Fire", "ncode"])
        #expect(plan.changes.map(\.position) == [1, 2, 4], "Fire is untouched, so it is not listed")
        #expect(plan.changes.map(\.summary) == [
            "#1 POLICE DEPT → POLICE (cut to 7 characters)",
            "#2 POLICE DIV → POLICE2 (cut to 7 characters)",
            "#4 Ünïcode → ncode (plain ASCII only)",
        ])
    }

    @Test func aRepeatIsRemovedAndNamesTheChannelItRepeats() {
        let codeplug = plug([channel("A", 155.475, tone: 123.0), channel("B", 155.475, tone: 123.0), channel("C", 155.475)])
        let plan = CodeplugFixPlan.make(for: codeplug)

        #expect(plan.fixed.channels.map(\.name) == ["A", "C"])
        #expect(plan.changes.count == 1)
        #expect(plan.changes.first?.kind == .removedDuplicate(of: 1))
        #expect(plan.changes.first?.summary == "#2 B removed: a repeat of #1 (A)")
    }

    @Test func overflowIsDroppedAfterRepeatsAreRemoved() {
        var channels = (0...128).map { channel("C\($0)", 150 + Double($0) * 0.01) }
        channels.append(channel("C0 again", 150))
        let plan = CodeplugFixPlan.make(for: plug(channels))

        #expect(plan.fixed.channels.count == 128)
        #expect(plan.changes.first { $0.position == 130 }?.kind == .removedDuplicate(of: 1))
        let dropped = plan.changes.first { $0.position == 129 }
        #expect(dropped?.kind == .droppedOverCapacity)
        #expect(dropped?.summary == "#129 C128 dropped: the Baofeng UV-5R holds 128 channels")
        #expect(plan.changes.count == 2)
    }

    @Test func theFixedCodeplugIsWhatTheExistingFixesProduce() {
        let codeplug = plug([channel("POLICE DEPT", 155.1), channel("POLICE DEPT", 155.1), channel("POLICE DIV", 155.2),
                             channel("TG", 0, talkgroup: 5), channel("Ünïcode", 154.4)])
        #expect(CodeplugFixPlan.make(for: codeplug).fixed.channels == appliedTheExistingWay(codeplug).channels)
    }

    @Test func changesAreListedInTheOrderOfTheCodeplug() {
        let codeplug = plug([channel("LONG NAME ONE", 155.1), channel("A", 155.5), channel("B", 155.5), channel("LONG NAME TWO", 155.3)])
        let positions = CodeplugFixPlan.make(for: codeplug).changes.map(\.position)

        #expect(positions == positions.sorted())
        #expect(positions == [1, 3, 4])
    }
}

extension CodeplugFixPlanTests {
    @Test func aPreviewedPlanAppliesToTheCodeplugItWasMadeFrom() {
        let codeplug = plug([channel("POLICE DEPT", 155.1), channel("Fire", 154.3)])
        let plan = CodeplugFixPlan.make(for: codeplug)

        #expect(plan.applying(to: codeplug)?.channels == plan.fixed.channels)
    }

    @Test func aPlanIsRefusedWhenTheCodeplugChangedAfterThePreview() {
        var codeplug = plug([channel("POLICE DEPT", 155.1), channel("Fire", 154.3)])
        let plan = CodeplugFixPlan.make(for: codeplug)
        codeplug.channels.append(channel("EMS DISPATCH", 154.2))

        #expect(plan.applying(to: codeplug) == nil, "what was previewed is no longer what would happen")
    }

    @Test func anEmptyPlanAppliesToNothing() {
        let codeplug = plug([channel("FIRE", 154.3)])
        #expect(CodeplugFixPlan.make(for: codeplug).applying(to: codeplug) == nil)
    }
}

// MARK: - Review

struct CodeplugReviewTests {
    private let mixed = plug([channel("SHERIFF DEPT", 155.475), channel("", 154.28), channel("TG101", 0, talkgroup: 101)])

    @Test func theHeadlineCountsProblemsChecksAndNotes() {
        let review = CodeplugReview.make(for: mixed)

        #expect(review.counts.errors == 1 && review.counts.warnings == 2 && review.counts.notes == 0)
        #expect(review.headline == "3 channels for the Baofeng UV-5R: 1 problem, 2 to check.")
    }

    @Test func aCleanCodeplugSaysSoAndSuggestsNothing() {
        let review = CodeplugReview.make(for: plug([channel("SHERIFF", 155.475), channel("FIRE", 154.28)]))

        #expect(review.headline == "2 channels for the Baofeng UV-5R: no problems found.")
        #expect(review.lines.isEmpty)
        #expect(review.recommendation == nil)
    }

    @Test func anEmptyCodeplugIsNotCalledClean() {
        let review = CodeplugReview.make(for: plug([]))

        #expect(review.headline == "The codeplug is empty.")
        #expect(review.lines == ["Add channels from Browse, Search, Scanner or Trunked, then review it."])
    }

    @Test func eachFindingIsALineWithItsSeverityAndChannel() {
        let lines = CodeplugReview.make(for: mixed).lines

        #expect(lines.contains { $0.hasPrefix("Problem #3 TG101: A talkgroup has no frequency") })
        #expect(lines.contains { $0.hasPrefix("Check #1 SHERIFF DEPT: ") && $0.contains("longer than") })
        #expect(lines.contains { $0.hasPrefix("Check #2 (no name): ") })
    }

    @Test func proposedFixesAreLabelledAsNotYetDone() {
        let lines = CodeplugReview.make(for: mixed).lines

        #expect(lines.contains("Proposed fixes (nothing has been changed):"))
        #expect(lines.contains("#1 SHERIFF DEPT → SHERIFF (cut to 7 characters)"))
    }

    @Test func whatNeedsAHumanIsSeparatedFromWhatCanBeFixed() {
        let review = CodeplugReview.make(for: mixed)

        #expect(review.lines.contains("2 findings need your decision: the app cannot pick a frequency, tone or mode for you."))
        #expect(review.recommendation == "Preview the proposed fixes and apply them if they look right, then settle the 2 findings that need your decision by hand.")
    }

    @Test func whenNothingCanBeFixedAutomaticallyTheRecommendationSaysSo() {
        let review = CodeplugReview.make(for: plug([channel("TG101", 0, talkgroup: 101)]))

        #expect(review.plan.isEmpty)
        #expect(review.recommendation == "Settle the 1 finding by hand; the app has no safe automatic fix for it.")
    }

    @Test func aLongListOfFindingsIsCappedAndSaysHowManyMore() {
        let many = plug((0..<20).map { channel("", 150 + Double($0) * 0.01) })
        let lines = CodeplugReview.make(for: many).lines

        #expect(lines.filter { $0.hasPrefix("Check #") }.count == 12)
        #expect(lines.contains("…and 8 more findings."))
    }
}

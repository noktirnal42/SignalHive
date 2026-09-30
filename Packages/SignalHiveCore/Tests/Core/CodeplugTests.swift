import Testing
import Foundation
@testable import SignalHiveCore

private func channel(_ name: String, _ mhz: Double, mode: ChannelMode = .nfm, offset: Double = 0, tone: Double = 0, dcs: Int = 0,
                     talkgroup: Int = 0) -> CodeplugChannel {
    CodeplugChannel(name: name, frequencyHz: mhz * 1_000_000, offsetHz: offset, mode: mode, ctcssToneHz: tone, dtcsCode: dcs,
                    talkgroupID: talkgroup)
}

struct ToneCatalogTests {
    @Test func ctcssHasTheFiftyStandardTonesInOrder() {
        #expect(CTCSSCatalog.tones.count == 50)
        #expect(CTCSSCatalog.tones == CTCSSCatalog.tones.sorted())
        #expect(Set(CTCSSCatalog.tones).count == 50, "no tone is listed twice")
        #expect(CTCSSCatalog.tones.contains(159.8) && CTCSSCatalog.tones.contains(210.7))
        #expect(CTCSSCatalog.isStandard(100.0) && CTCSSCatalog.isStandard(100.04))
        #expect(!CTCSSCatalog.isStandard(100.5))
    }

    @Test func dcsHasTheStandardCodes() {
        #expect(DCSCatalog.codes.count == 104)
        #expect(Set(DCSCatalog.codes).count == 104)
        #expect(DCSCatalog.isStandard(23) && DCSCatalog.isStandard(754))
        #expect(!DCSCatalog.isStandard(24))
    }
}

struct RadioCapabilityTests {
    @Test func baofengsCoverVHFAndUHFButNotAirband() {
        let radio = RadioTarget.baofengUV5R
        #expect(radio.covers(155_475_000) && radio.covers(462_562_500))
        #expect(!radio.covers(121_900_000))
        #expect(radio.maxNameLength == 7)
        #expect(radio.supportedModes == [.fm, .nfm])
        #expect(!radio.supportsTalkgroups && !radio.isReceiveOnly)
    }

    @Test func scannersCoverAirbandAndFollowTalkgroups() {
        for radio in [RadioTarget.unidenBCD436HP, .unidenSDS100] {
            #expect(radio.covers(121_900_000) && radio.covers(155_475_000) && radio.covers(851_000_000))
            #expect(!radio.covers(600_000_000), "a gap between the TV and 700 MHz bands")
            #expect(radio.supportsTalkgroups && radio.isReceiveOnly)
        }
    }

    @Test func everyTargetHasSaneLimits() {
        for radio in RadioTarget.allCases {
            #expect(radio.maxNameLength >= 7 && radio.channelCapacity > 0)
            #expect(!radio.supportedModes.isEmpty && !radio.frequencyRanges.isEmpty)
        }
    }

    @Test func bandsHaveNames() {
        #expect(RadioBand.name(for: 121_900_000) == "Airband")
        #expect(RadioBand.name(for: 146_520_000) == "2 m ham")
        #expect(RadioBand.name(for: 156_800_000) == "Marine VHF")
        #expect(RadioBand.name(for: 162_550_000) == "NOAA weather")
        #expect(RadioBand.name(for: 155_475_000) == "VHF")
        #expect(RadioBand.name(for: 462_562_500) == "FRS / GMRS")
        #expect(RadioBand.name(for: 851_000_000) == "800 MHz")
        #expect(RadioBand.name(for: 0) == "No frequency")
        #expect(RadioBand.name(for: 7_000_000) == "HF")
    }
}

struct CodeplugValidatorTests {
    private func plug(_ channels: [CodeplugChannel], target: RadioTarget = .baofengUV5R) -> Codeplug {
        Codeplug(name: "Test", target: target, channels: channels)
    }

    private func codes(_ issues: [CodeplugIssue]) -> [CodeplugIssue.Code] { issues.map(\.code) }

    @Test func aCleanCodeplugHasNoIssues() {
        let issues = CodeplugValidator.validate(plug([channel("SHERIFF", 155.475, tone: 123.0), channel("FIRE", 154.28)]))
        #expect(issues.isEmpty)
    }

    @Test func tooManyChannelsIsAProblem() {
        let channels = (0..<130).map { channel("CH\($0)", 150 + Double($0) * 0.01) }
        let issues = CodeplugValidator.validate(plug(channels))
        let capacity = issues.first { $0.code == .overCapacity }
        #expect(capacity?.severity == .error)
        #expect(capacity?.message.contains("last 2") == true)
        #expect(capacity?.channelID == nil)
    }

    @Test func namesTheRadioCannotShowAreFlagged() {
        let issues = CodeplugValidator.validate(plug([channel("SHERIFF DEPT", 155.475), channel("", 154.28)]))
        #expect(codes(issues).contains(.nameTooLong) && codes(issues).contains(.emptyName))
        #expect(issues.first { $0.code == .nameTooLong }?.message.contains("SHERIFF") == true)
        #expect(issues.first { $0.code == .nameTooLong }?.position == 1)
        #expect(CodeplugValidator.validate(plug([channel("SHERIFF DEPT", 155.475)], target: .unidenSDS100)).isEmpty, "16 characters fit")
    }

    @Test func channelsWithoutAFrequencyAreProblemsUnlessTheRadioFollowsTalkgroups() {
        let onBaofeng = CodeplugValidator.validate(plug([channel("TG101", 0, talkgroup: 101)]))
        #expect(onBaofeng.first?.code == .noFrequency && onBaofeng.first?.severity == .error)
        #expect(onBaofeng.first?.message.contains("talkgroup") == true)

        let onUniden = CodeplugValidator.validate(plug([channel("TG101", 0, mode: .p25, talkgroup: 101)], target: .unidenBCD436HP))
        #expect(onUniden.first?.code == .talkgroupOnly && onUniden.first?.severity == .info)

        let plain = CodeplugValidator.validate(plug([channel("X", 0)]))
        #expect(plain.first?.code == .noFrequency)
    }

    @Test func frequenciesOutsideTheRadiosBandsAreWarnings() {
        let air = channel("AIR", 121.9, mode: .am)
        #expect(codes(CodeplugValidator.validate(plug([air]))).contains(.outOfRange))
        #expect(!codes(CodeplugValidator.validate(plug([air], target: .unidenBCD436HP))).contains(.outOfRange))
    }

    @Test func modesTheRadioCannotDecodeAreProblems() {
        let issues = CodeplugValidator.validate(plug([channel("DMR1", 154.0, mode: .dmr), channel("AM1", 154.1, mode: .am)]))
        #expect(issues.filter { $0.code == .unsupportedMode }.count == 2)
        #expect(issues.allSatisfy { $0.severity == .error })
    }

    @Test func repeatedChannelsAndNamesAreNoticed() {
        let issues = CodeplugValidator.validate(plug([
            channel("SHERIFF", 155.475, tone: 123.0), channel("COPY", 155.475, tone: 123.0),
            channel("SHERIFF", 155.520), channel("OTHER", 155.475, tone: 100.0),
        ]))
        let duplicate = issues.first { $0.code == .duplicateChannel }
        #expect(duplicate?.position == 2 && duplicate?.message.contains("#1") == true)
        #expect(issues.filter { $0.code == .duplicateChannel }.count == 1, "a different tone makes a different channel")
        let sameName = issues.first { $0.code == .duplicateName }
        #expect(sameName?.position == 3 && sameName?.severity == .info)
    }

    @Test func oddTonesAndConflictsAreWarnings() {
        let issues = CodeplugValidator.validate(plug([
            channel("A", 155.1, tone: 100.5), channel("B", 155.2, dcs: 24), channel("C", 155.3, tone: 100.0, dcs: 23),
        ]))
        #expect(issues.filter { $0.code == .nonStandardTone }.count == 2)
        #expect(issues.filter { $0.code == .toneConflict }.count == 1)
    }

    @Test func aHugeOffsetIsWarnedAbout() {
        let issues = CodeplugValidator.validate(plug([channel("RPT", 146.94, offset: -15_000_000)]))
        #expect(codes(issues).contains(.hugeOffset))
        #expect(!codes(CodeplugValidator.validate(plug([channel("RPT", 146.94, offset: -600_000)]))).contains(.hugeOffset))
    }

    @Test func issuesAreListedWorstFirstThenInOrder() {
        let issues = CodeplugValidator.validate(plug([
            channel("SHERIFF DEPT", 155.475), channel("DMR1", 154.0, mode: .dmr), channel("X", 0),
        ]))
        let severities = issues.map(\.severity)
        #expect(severities == severities.sorted(by: >))
        let errors = issues.filter { $0.severity == .error }
        #expect(errors.map { $0.position ?? 0 } == errors.map { $0.position ?? 0 }.sorted())
        let counts = CodeplugValidator.counts(issues)
        #expect(counts.errors == 2 && counts.warnings == 1 && counts.notes == 0)
    }

    @Test func everyIssueHasItsOwnIdentity() {
        // One channel with a bad tone, a bad code and both set: two "non-standard tone" issues and a conflict.
        let issues = CodeplugValidator.validate(plug([channel("A", 155.1, tone: 100.5, dcs: 24)]))
        #expect(issues.count == 3)
        #expect(Set(issues.map(\.id)).count == 3)
    }
}

struct CodeplugEditingTests {
    private func plug(_ names: [String]) -> Codeplug {
        Codeplug(name: "T", target: .baofengUV5R, channels: names.enumerated().map { channel($0.element, 150 + Double($0.offset)) })
    }

    private func names(_ plug: Codeplug) -> [String] { plug.channels.map(\.name) }

    @Test func dragAndDropReordersLikeAList() {
        var forward = plug(["a", "b", "c", "d"])
        forward.moveChannels(from: [0], to: 3)
        #expect(names(forward) == ["b", "c", "a", "d"])

        var backward = plug(["a", "b", "c", "d"])
        backward.moveChannels(from: [3], to: 0)
        #expect(names(backward) == ["d", "a", "b", "c"])

        var several = plug(["a", "b", "c", "d"])
        several.moveChannels(from: [1, 2], to: 4)
        #expect(names(several) == ["a", "d", "b", "c"])

        var toFront = plug(["a", "b", "c", "d"])
        toFront.moveChannels(from: [1, 3], to: 0)
        #expect(names(toFront) == ["b", "d", "a", "c"])

        var nothing = plug(["a", "b"])
        nothing.moveChannels(from: [], to: 1)
        nothing.moveChannels(from: [9], to: 0)
        #expect(names(nothing) == ["a", "b"])
    }

    @Test func aChannelIsUpdatedInPlaceByIdentity() {
        var codeplug = plug(["a", "b"])
        var edited = codeplug.channels[1]
        edited.name = "B2"
        edited.ctcssToneHz = 88.5
        codeplug.update(edited)
        #expect(names(codeplug) == ["a", "B2"] && codeplug.channels[1].ctcssToneHz == 88.5)
        codeplug.update(CodeplugChannel(name: "stranger", frequencyHz: 1))
        #expect(codeplug.channels.count == 2)
    }

    @Test func duplicatingPutsTheCopyRightAfter() {
        var codeplug = plug(["a", "b"])
        codeplug.duplicate(channelID: codeplug.channels[0].id)
        #expect(names(codeplug) == ["a", "a", "b"])
        #expect(codeplug.channels[0].id != codeplug.channels[1].id)
    }

    @Test func sortingPutsTalkgroupOnlyChannelsLast() {
        var codeplug = Codeplug(name: "T", target: .unidenSDS100, channels: [
            channel("HIGH", 460.0), channel("TG", 0, talkgroup: 5), channel("LOW", 150.0),
        ])
        codeplug.sortByFrequency()
        #expect(names(codeplug) == ["LOW", "HIGH", "TG"])
    }

    @Test func duplicatesAreRemovedKeepingTheFirst() {
        var codeplug = Codeplug(name: "T", target: .baofengUV5R, channels: [
            channel("A", 155.475, tone: 123.0), channel("B", 155.475, tone: 123.0), channel("C", 155.475),
            channel("TG1", 0, talkgroup: 1), channel("TG2", 0, talkgroup: 2),
        ])
        #expect(codeplug.removeDuplicates() == 1)
        #expect(names(codeplug) == ["A", "C", "TG1", "TG2"])
        #expect(codeplug.removeDuplicates() == 0)
    }

    @Test func fittingShortensNamesKeepsThemDistinctAndDropsTheOverflow() {
        var codeplug = Codeplug(name: "T", target: .baofengUV5R, channels: [
            channel("POLICE DEPT", 155.1), channel("POLICE DIV", 155.2), channel("Fire", 154.3), channel("Ünïcode", 154.4),
        ])
        let result = codeplug.fitToRadio()
        #expect(names(codeplug) == ["POLICE", "POLICE2", "Fire", "ncode"])
        #expect(result.shortenedNames == 3 && result.dropped == 0)
        #expect(codeplug.channels.allSatisfy { $0.name.count <= 7 })

        var big = Codeplug(name: "T", target: .baofengUV5R, channels: (0..<130).map { channel("C\($0)", 150 + Double($0) * 0.01) })
        #expect(big.fitToRadio().dropped == 2 && big.channels.count == 128)
    }

    @Test func bandSummaryCountsChannelsPerBand() {
        let codeplug = Codeplug(name: "T", target: .unidenSDS100, channels: [
            channel("A", 121.9, mode: .am), channel("B", 121.5, mode: .am), channel("C", 146.52), channel("D", 155.475),
            channel("E", 155.52),
        ])
        let summary = codeplug.bandSummary
        #expect(summary.first?.band == "Airband" || summary.first?.band == "VHF")
        #expect(Dictionary(uniqueKeysWithValues: summary.map { ($0.band, $0.count) }) == ["Airband": 2, "2 m ham": 1, "VHF": 2])
    }
}

struct CHIRPImporterTests {
    @Test func aCHIRPExportIsReadByColumnName() {
        // Columns in a different order, with an extra one, as CHIRP writes for some radios.
        let csv = """
        Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,Mode,TStep,Skip,Power,Comment
        0,SHERIFF,155.475000,,0.600000,Tone,123.0,88.5,023,NN,NFM,5.00,,5.0W,County sheriff
        1,RPT,146.880000,-,0.600000,TSQL,100.0,110.9,023,NN,FM,5.00,,50W,"2 m, local"
        2,DCS,151.100000,,0.000000,DTCS,88.5,88.5,047,NN,NFM,5.00,,,
        3,AIR,121.900000,,0.000000,,88.5,88.5,023,NN,AM,5.00,,,
        """
        let result = CHIRPCSVImporter.parse(csv)
        #expect(result.skipped.isEmpty)
        #expect(result.channels.count == 4)
        let sheriff = result.channels[0]
        #expect(sheriff.name == "SHERIFF" && sheriff.frequencyHz == 155_475_000 && sheriff.ctcssToneHz == 123.0)
        #expect(sheriff.offsetHz == 0, "a blank duplex means simplex whatever the offset column says")
        #expect(sheriff.notes == "County sheriff" && sheriff.powerWatts == 5 && sheriff.mode == .nfm)
        let repeater = result.channels[1]
        #expect(repeater.offsetHz == -600_000 && repeater.ctcssToneHz == 110.9, "TSQL uses the receive tone")
        #expect(repeater.notes == "2 m, local" && repeater.powerWatts == 50 && repeater.mode == .fm)
        #expect(result.channels[2].dtcsCode == 47 && result.channels[2].ctcssToneHz == 0)
        #expect(result.channels[3].mode == .am && result.channels[3].powerWatts == 5, "no power given: the default")
    }

    @Test func badRowsAreSkippedAndReportedNotFatal() {
        let csv = "Location,Name,Frequency,Mode\n0,OK,155.475,NFM\n1,SHORT\n2,BAD,abc,FM\n\n3,ALSO,154.28,FM\n"
        let result = CHIRPCSVImporter.parse(csv)
        #expect(result.channels.map(\.name) == ["OK", "ALSO"])
        #expect(result.skipped.count == 2)
        #expect(result.skipped[0].hasPrefix("line 3") && result.skipped[1].hasPrefix("line 4"))
    }

    @Test func aFileWithoutAFrequencyColumnIsRefusedPolitely() {
        let result = CHIRPCSVImporter.parse("Name,Mode\nX,FM\n")
        #expect(result.channels.isEmpty && result.skipped.count == 1)
        #expect(CHIRPCSVImporter.parse("").channels.isEmpty)
    }

    @Test func quotedFieldsMayHoldCommasQuotesAndLineBreaks() {
        let csv = "Location,Name,Frequency,Mode,Comment\r\n0,\"A, B\",155.475,NFM,\"say \"\"hi\"\"\r\nsecond line\"\r\n1,C,154.28,FM,\r\n"
        let result = CHIRPCSVImporter.parse(csv)
        #expect(result.channels.count == 2)
        #expect(result.channels[0].name == "A, B")
        #expect(result.channels[0].notes == "say \"hi\"\r\nsecond line")
        #expect(result.channels[1].name == "C")
    }

    @Test func whatWeExportWeCanImportAgain() throws {
        let original = [
            CodeplugChannel(name: "SHERIFF", frequencyHz: 155_475_000, mode: .nfm, ctcssToneHz: 123.0, powerWatts: 5, notes: "County"),
            CodeplugChannel(name: "A, B", frequencyHz: 146_880_000, offsetHz: -600_000, mode: .fm, powerWatts: 8),
            CodeplugChannel(name: "DCS", frequencyHz: 151_100_000, mode: .nfm, dtcsCode: 47, powerWatts: 1),
            CodeplugChannel(name: "AIR", frequencyHz: 121_900_000, mode: .am, powerWatts: 5, notes: "Comment, with comma"),
        ]
        let csv = try CHIRPCSVExporter.csv(for: original)
        let result = CHIRPCSVImporter.parse(csv)
        #expect(result.skipped.isEmpty && result.channels.count == 4)
        for (before, after) in zip(original, result.channels) {
            #expect(after.name == before.name && after.frequencyHz == before.frequencyHz && after.offsetHz == before.offsetHz)
            #expect(after.mode == before.mode && after.ctcssToneHz == before.ctcssToneHz && after.dtcsCode == before.dtcsCode)
            #expect(after.powerWatts == before.powerWatts && after.notes == before.notes)
        }
    }

    @Test func theOldEntryPointStillWorks() {
        let csv = "Location,Name,Frequency,Mode\n0,X,155.475,NFM\n"
        #expect(CHIRPCSVExporter.parse(csv: csv).count == 1)
    }
}

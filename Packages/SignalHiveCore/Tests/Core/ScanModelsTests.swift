import Testing
@testable import SignalHiveCore

struct ScanModelsTests {
    @Test func scanListUpsertMergesOnTheChannelGrid() {
        var list = ScanList(name: "Local")
        list.upsert(ScanChannel(name: "First", frequencyHz: 155_475_000))
        list.upsert(ScanChannel(name: "Updated", frequencyHz: 155_475_900))

        #expect(list.channels.count == 1)
        #expect(list.channels[0].name == "Updated")
    }

    @Test func activityLogMergesRepeatedHitsAndMarksLockouts() {
        var log = ScanActivityLog()
        let first = FoundFrequency(frequencyHz: 155_475_000, strengthDB: -42, noiseFloorDB: -84, bandwidthHz: 12_500)
        let repeatHit = FoundFrequency(frequencyHz: 155_475_100, strengthDB: -39, noiseFloorDB: -82, bandwidthHz: 12_500)

        log.ingest([first])
        log.ingest([repeatHit], lockedOutKeys: [ScanActivity.key(for: repeatHit.frequencyHz)])

        #expect(log.hits.count == 1)
        #expect(log.hits[0].hitCount == 2)
        #expect(log.hits[0].lockedOut)
        #expect(log.hits[0].snrDB == 43)
    }

    @Test func scanChannelsConvertToCodeplugChannels() {
        let channel = ScanChannel(name: "Air Guard", frequencyHz: 121_500_000, mode: .am, source: .preset)
        let codeplug = channel.codeplugChannel()

        #expect(codeplug.name == "Air Guard")
        #expect(codeplug.frequencyHz == 121_500_000)
        #expect(codeplug.mode == .am)
        #expect(codeplug.sourceCallSign == "Preset")
    }
}

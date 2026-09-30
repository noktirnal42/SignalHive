import Testing
@testable import SignalHiveCore

struct FrequencyFinderTests {
    @Test func findsSignalsRelativeToTheLocalNoiseFloor() {
        var bins = [Float](repeating: -92, count: 1024)
        bins[620] = -70
        bins[621] = -48
        bins[622] = -68

        let found = FrequencyFinder.find(
            magnitudes: bins,
            centerFrequencyHz: 155_000_000,
            sampleRateHz: 2_048_000,
            thresholdDB: -90,
            minimumSNRDB: 10
        )

        #expect(found.count == 1)
        #expect(abs(found[0].frequencyHz - 155_218_000) < 2_100)
        #expect(found[0].snrDB ?? 0 > 35)
    }

    @Test func ignoresTheDongleDCSpike() {
        var bins = [Float](repeating: -90, count: 1024)
        bins[512] = -20

        let found = FrequencyFinder.find(
            magnitudes: bins,
            centerFrequencyHz: 155_000_000,
            sampleRateHz: 2_048_000,
            thresholdDB: -90,
            minimumSNRDB: 10
        )

        #expect(found.isEmpty)
    }
}

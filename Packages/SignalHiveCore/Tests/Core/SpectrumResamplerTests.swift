import Testing
@testable import SignalHiveCore

struct SpectrumResamplerTests {
    @Test func maxPoolingKeepsTheStrongestBinOfEachGroup() {
        #expect(SpectrumResampler.maxPool([1, 5, 2, 3, 9, 0, 4, 4], to: 4) == [5, 3, 9, 4])
    }

    @Test func aNarrowSignalSurvivesHeavyReduction() {
        var bins = [Float](repeating: -100, count: 4096)
        bins[3000] = -20                                                    // one strong narrow carrier
        let pooled = SpectrumResampler.maxPool(bins, to: 256)
        #expect(pooled.count == 256)
        #expect(pooled.max() == -20)
        #expect(pooled[3000 * 256 / 4096] == -20)                          // and it stays where it belongs
    }

    @Test func unevenSizesStillCoverEveryInputBin() {
        let pooled = SpectrumResampler.maxPool([1, 2, 3, 4, 5, 6, 7], to: 3)
        #expect(pooled.count == 3)
        #expect(pooled.max() == 7)
        #expect(pooled.first == 2)
    }

    @Test func requestingMoreBinsThanExistReturnsTheInputUnchanged() {
        #expect(SpectrumResampler.maxPool([1, 2, 3], to: 10) == [1, 2, 3])
        #expect(SpectrumResampler.maxPool([], to: 4).isEmpty)
        #expect(SpectrumResampler.maxPool([1, 2, 3], to: 0).isEmpty)
    }
}

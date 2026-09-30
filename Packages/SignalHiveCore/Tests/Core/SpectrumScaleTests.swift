import Testing
@testable import SignalHiveCore

struct SpectrumScaleTests {
    @Test func theScaleFollowsTheNoiseFloorNotAFixedRange() {
        let quiet = SpectrumScale.auto(for: [Float](repeating: -100, count: 512))
        let loud = SpectrumScale.auto(for: [Float](repeating: -50, count: 512))
        #expect(quiet.minDB < -100 && quiet.maxDB > -100)
        #expect(loud.minDB > quiet.minDB + 40)                        // same shape, shifted with the floor
        #expect(loud.maxDB - loud.minDB == quiet.maxDB - quiet.minDB)
    }

    @Test func aStrongPeakIsNeverClippedAndNoiseStaysNearTheBottom() {
        var bins = [Float](repeating: -100, count: 512)
        bins[200] = -20
        let scale = SpectrumScale.auto(for: bins)
        #expect(scale.maxDB >= -20)
        #expect(scale.normalized(-20) > 0.9)
        #expect(scale.normalized(-100) < 0.3)
    }

    @Test func normalizedValuesAreClampedToUnitRange() {
        let scale = SpectrumScale(minDB: -100, maxDB: -60)
        #expect(scale.normalized(-200) == 0)
        #expect(scale.normalized(-10) == 1)
        #expect(scale.normalized(-80) == 0.5)
    }

    @Test func emptyInputGivesAUsableDefaultRange() {
        let scale = SpectrumScale.auto(for: [])
        #expect(scale.maxDB > scale.minDB)
    }
}

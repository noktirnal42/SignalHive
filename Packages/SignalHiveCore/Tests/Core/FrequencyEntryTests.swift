import Testing
@testable import SignalHiveCore

struct FrequencyEntryTests {
    @Test(arguments: [
        ("155.475", 155.475), ("155,475", 155.475), ("155.475 MHz", 155.475), ("  155.475mhz ", 155.475),
        ("162550 kHz", 162.55), ("155475000", 155.475), ("155475000 Hz", 155.475), ("0.9 GHz", 900.0),
        ("1090", 1090.0),          // in the tuner's MHz range: ADS-B
        ("121500", 121.5),         // outside it, so kilohertz: airband emergency
        ("162.4", 162.4),
    ])
    func typedFrequenciesBecomeMegahertz(text: String, expected: Double) {
        let parsed = FrequencyEntry.parseMHz(text)
        #expect(parsed != nil)
        #expect(abs((parsed ?? 0) - expected) < 1e-9)
    }

    @Test(arguments: ["", "abc", "-5", "0", "155.4.75", "MHz"])
    func nonsenseIsRejected(text: String) {
        #expect(FrequencyEntry.parseMHz(text) == nil)
    }

    @Test func snappingLandsOnTheChannelGrid() {
        #expect(FrequencyEntry.snap(mhz: 160.38954, stepKHz: 12.5) == 160.3875)
        #expect(FrequencyEntry.snap(mhz: 160.394, stepKHz: 12.5) == 160.4)
        #expect(FrequencyEntry.snap(mhz: 155.4751, stepKHz: 5) == 155.475)
        #expect(FrequencyEntry.snap(mhz: 462.5625, stepKHz: 12.5) == 462.5625)
    }

    @Test func aZeroStepLeavesTheFrequencyAlone() {
        #expect(FrequencyEntry.snap(mhz: 100.123, stepKHz: 0) == 100.123)
    }
}

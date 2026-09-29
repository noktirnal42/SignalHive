import Testing
@testable import SignalHiveCore

struct EmissionDesignatorTests {
    @Test(arguments: [
        ("20K0F3E", 20000.0, ModeHint.analogFM),
        ("11K2F3E", 11200.0, ModeHint.analogFM),
        ("20K0F2D", 20000.0, ModeHint.analogFM),
        ("8K10F1E", 8100.0, ModeHint.digitalP25),
        ("8K10F1W", 8100.0, ModeHint.digitalP25),
        ("16K0F1E", 16000.0, ModeHint.digitalOther),
        ("20K0G7W", 20000.0, ModeHint.digitalOther),
        ("4K00J3E", 4000.0, ModeHint.ssb),
        ("6K00A3E", 6000.0, ModeHint.am),
    ]) func parses(code: String, bandwidth: Double, mode: ModeHint) {
        let info = EmissionDesignator.parse(code)
        #expect(info.bandwidthHz == bandwidth)
        #expect(info.modeHint == mode)
    }

    @Test func garbageIsUnknownWithNoBandwidth() {
        #expect(EmissionDesignator.parse("") == EmissionInfo(bandwidthHz: nil, modeHint: .unknown))
        #expect(EmissionDesignator.parse("hello") == EmissionInfo(bandwidthHz: nil, modeHint: .unknown))
    }

    @Test func lowercaseAndPaddingAreTolerated() {
        #expect(EmissionDesignator.parse(" 20k0f3e ").modeHint == .analogFM)
    }
}

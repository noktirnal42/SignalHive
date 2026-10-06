import Testing
import Foundation
@testable import SignalHiveCore

struct AntennaProfileTests {
    private func antenna(low: Double, high: Double) -> AntennaProfile {
        AntennaProfile(id: UUID(), name: "test", lowHz: low, highHz: high, gain: .omni, isDirectional: false, notes: "")
    }

    @Test func coversIsInclusiveAtBothEdges() {
        let a = antenna(low: 100e6, high: 800e6)
        #expect(a.covers(100e6) && a.covers(800e6) && a.covers(137.9e6))
        #expect(!a.covers(99_999_999) && !a.covers(800_000_001))
        #expect(!a.covers(.nan))
    }

    @Test func codableRoundTrip() throws {
        let original = AntennaProfile(id: UUID(), name: "Homebrew turnstile", lowHz: 136e6, highHz: 138e6, gain: .medium,
                                      isDirectional: true, notes: "built 2026")
        let decoded = try JSONDecoder().decode(AntennaProfile.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func presetsHaveTheMakersBands() throws {
        let presets = AntennaProfile.presets
        #expect(presets.count == 3)
        #expect(Set(presets.map(\.id)).count == 3, "preset ids must be distinct and stable")
        let telescopic = try #require(presets.first { $0.name.lowercased().contains("telescopic") })
        #expect(telescopic.lowHz == 100e6 && telescopic.highHz == 800e6 && !telescopic.isDirectional && telescopic.gain == .omni)
        #expect(telescopic.covers(137.9e6) && telescopic.covers(162.55e6) && !telescopic.covers(1090e6))
        let dvbt = try #require(presets.first { $0.name.contains("DVB-T") })
        #expect(dvbt.lowHz == 700e6 && dvbt.highHz == 1200e6 && dvbt.covers(1090e6) && !dvbt.covers(137.9e6))
        let helical = try #require(presets.first { $0.name.lowercased().contains("helical") })
        #expect(helical.lowHz == 1100e6 && helical.highHz == 1800e6 && helical.covers(1701.3e6))
        #expect(presets.allSatisfy { $0.notes.contains("not measured") })
    }

    @Test func presetIdsAreTheSameOnEveryLaunch() {
        #expect(AntennaProfile.presets.map(\.id) == AntennaProfile.presets.map(\.id))
        #expect(AntennaProfile.presets.first?.id == UUID(uuidString: "5A7E1C00-0000-4000-8000-000000000001"))
    }

    @Test func receiverCapabilityIsTheRTLSDRRange() {
        #expect(ReceiverCapability.rtlSDR.tuningRangeHz == 24e6...1_766e6)
    }
}

import Testing
import Foundation
@testable import SignalHiveCore

private func elements(_ id: Int, _ name: String = "SAT") -> OrbitalElements {
    OrbitalElements(name: "\(name) \(id)", noradID: id, epoch: Date(timeIntervalSince1970: 1_790_000_000),
                    inclinationDegrees: 98.7, raanDegrees: 10, eccentricity: 0.001, argumentOfPerigeeDegrees: 20,
                    meanAnomalyDegrees: 30, meanMotionRevsPerDay: 14.2, bstar: 1e-5)
}

private func transmitter(_ id: String, norad: Int, mhz: Double, mode: String? = "LRPT", active: Bool = true,
                         baud: Double? = nil, verified: Date? = nil) -> TransmitterInfo {
    TransmitterInfo(id: id, noradID: norad, summary: "test \(id)", downlinkHz: mhz * 1e6, mode: mode,
                    kind: SignalKind(satnogsMode: mode, baud: baud), isActive: active, service: nil, verifiedOnAir: verified)
}

private let noOverrides = TransmitterOverrides(strengths: [:], notes: [:], verified: [])

struct SatelliteDirectoryTests {
    @Test func deadAndReenteredSatellitesAreExcluded() {
        let groups: [SatelliteCategory: [OrbitalElements]] = [.weather: [elements(1), elements(2), elements(3), elements(4), elements(5)]]
        let statuses: [Int: SatelliteStatus] = [1: .alive, 2: .dead, 3: .reentered, 4: .future]
        let records = SatelliteDirectory.build(groups: groups, satellites: statuses, transmitters: [], overrides: noOverrides)
        // 5 has no SatNOGS entry (unknown): CelesTrak still tracks it, so it stays.
        #expect(records.map(\.elements.noradID).sorted() == [1, 5])
        #expect(records.first { $0.elements.noradID == 5 }?.status == .unknown)
    }

    @Test func satelliteWithoutAnActiveTransmitterInRangeHasNoPrimary() {
        let groups: [SatelliteCategory: [OrbitalElements]] = [.weather: [elements(1), elements(2)]]
        let transmitters = [transmitter("a", norad: 1, mhz: 137.1, active: false)]
        let records = SatelliteDirectory.build(groups: groups, satellites: [1: .alive, 2: .alive], transmitters: transmitters, overrides: noOverrides)
        #expect(records.allSatisfy { $0.primaryTransmitter == nil })
        #expect(records.first { $0.elements.noradID == 1 }?.transmitters.count == 1, "the inactive transmitter is still listed")
    }

    @Test func transmitterOutside24To1766MHzIsNotPrimary() {
        let groups: [SatelliteCategory: [OrbitalElements]] = [.weather: [elements(1)]]
        for mhz in [10.0, 23.9, 1766.1, 2247.5, 8128.0] {
            let records = SatelliteDirectory.build(groups: groups, satellites: [1: .alive],
                                                   transmitters: [transmitter("x", norad: 1, mhz: mhz)], overrides: noOverrides)
            #expect(records.first?.primaryTransmitter == nil, "\(mhz) MHz")
        }
        for mhz in [24.0, 137.1, 1766.0] {
            let records = SatelliteDirectory.build(groups: groups, satellites: [1: .alive],
                                                   transmitters: [transmitter("x", norad: 1, mhz: mhz)], overrides: noOverrides)
            #expect(records.first?.primaryTransmitter?.downlinkHz == mhz * 1e6, "\(mhz) MHz")
        }
    }

    @Test func primaryIsTheActiveOneWithTheBestDecoderStatus() {
        let groups: [SatelliteCategory: [OrbitalElements]] = [.weather: [elements(1)]]
        let transmitters = [
            transmitter("telemetry", norad: 1, mhz: 100.0, mode: "BPSK"),
            transmitter("lrptHigh", norad: 1, mhz: 137.9, mode: "LRPT"),
            transmitter("lrptLow", norad: 1, mhz: 137.1, mode: "LRPT"),
            transmitter("deadLrpt", norad: 1, mhz: 137.5, mode: "LRPT", active: false),
        ]
        let records = SatelliteDirectory.build(groups: groups, satellites: [1: .alive], transmitters: transmitters, overrides: noOverrides)
        // Equal decoder status: the lowest frequency, so the choice does not depend on feed order.
        #expect(records.first?.primaryTransmitter?.id == "lrptLow")
        let reversed = SatelliteDirectory.build(groups: groups, satellites: [1: .alive], transmitters: transmitters.reversed(), overrides: noOverrides)
        #expect(reversed.first?.primaryTransmitter?.id == "lrptLow")
    }

    @Test func aVerifiedOnAirTransmitterOutranksUnverifiedOnes() {
        let groups: [SatelliteCategory: [OrbitalElements]] = [.weather: [elements(1)]]
        let verified = transmitter("verified", norad: 1, mhz: 137.9, mode: "LRPT", verified: Date(timeIntervalSince1970: 1_780_000_000))
        let overrides = TransmitterOverrides(strengths: [:], notes: [:], verified: [verified])
        let records = SatelliteDirectory.build(groups: groups, satellites: [1: .alive],
                                               transmitters: [transmitter("other", norad: 1, mhz: 137.1)], overrides: overrides)
        #expect(records.first?.primaryTransmitter?.id == "verified")
        #expect(records.first?.transmitters.count == 2)
    }

    @Test func overridesSetStrengthAndNote() throws {
        let overrides = try TransmitterOverrides.bundled()
        #expect(overrides.strength(for: 57166) == .weak) // METEOR-M2 3
        #expect(overrides.note(for: 57166)?.lowercased().contains("antenna") == true)
        #expect(overrides.note(for: 57166)?.lowercased().contains("deploy") == true)
        #expect(overrides.strength(for: 59051) == .medium) // METEOR-M2 4
        #expect(overrides.strength(for: 25544) == .unknown)
        #expect(overrides.note(for: 25544) == nil)
        #expect(overrides.transmitters(for: 59051).isEmpty, "nothing is verified on air yet")
    }

    @Test func recordsCarryStrengthAndNoteFromOverrides() {
        let overrides = TransmitterOverrides(strengths: [1: .weak], notes: [1: "antenna issue"], verified: [])
        let records = SatelliteDirectory.build(groups: [.weather: [elements(1), elements(2)]], satellites: [:], transmitters: [], overrides: overrides)
        #expect(records.first { $0.elements.noradID == 1 }?.strength == .weak)
        #expect(records.first { $0.elements.noradID == 1 }?.note == "antenna issue")
        #expect(records.first { $0.elements.noradID == 2 }?.strength == .unknown)
    }

    @Test func sixDigitIdsFlowThrough() {
        let records = SatelliteDirectory.build(groups: [.amateur: [elements(100_530)]], satellites: [100_530: .alive],
                                               transmitters: [transmitter("t", norad: 100_530, mhz: 145.8, mode: "FM")], overrides: noOverrides)
        #expect(records.first?.id == 100_530)
        #expect(records.first?.primaryTransmitter?.noradID == 100_530)
    }

    @Test func categoryComesFromTheGroupAndWeatherWinsOnDuplicates() {
        let groups: [SatelliteCategory: [OrbitalElements]] = [
            .weather: [elements(1)], .stations: [elements(1), elements(2)], .amateur: [elements(2), elements(3), elements(1)],
        ]
        let records = SatelliteDirectory.build(groups: groups, satellites: [:], transmitters: [], overrides: noOverrides)
        #expect(records.count == 3)
        #expect(records.first { $0.elements.noradID == 1 }?.category == .weather)
        #expect(records.first { $0.elements.noradID == 2 }?.category == .stations)
        #expect(records.first { $0.elements.noradID == 3 }?.category == .amateur)
    }

    @Test func fmOnAWeatherSatelliteIsNotVoice() {
        // SatNOGS labels many data downlinks "FM"; on a weather satellite that is not someone talking.
        let transmitters = [transmitter("weatherFM", norad: 1, mhz: 400.3, mode: "FM"), transmitter("hamFM", norad: 2, mhz: 145.8, mode: "FM")]
        let records = SatelliteDirectory.build(groups: [.weather: [elements(1)], .stations: [elements(2)]], satellites: [:],
                                               transmitters: transmitters, overrides: noOverrides)
        #expect(records.first { $0.elements.noradID == 1 }?.transmitters.first?.kind == .other)
        #expect(records.first { $0.elements.noradID == 2 }?.transmitters.first?.kind == .fmVoice)
    }

    @Test func realSampleBuildsAndKeepsMeteorsLrptAsPrimary() throws {
        let transmitters = try TransmitterStore.parseTransmitters(try Fixtures.data("satnogs-transmitters-sample.json")).transmitters
        let statuses = try TransmitterStore.parseSatellites(try Fixtures.data("satnogs-satellites-sample.json")).statuses
        let weather = try ElementParser.parseOMMJSON(try Fixtures.data("celestrak-weather-sample.json")).elements
        let records = SatelliteDirectory.build(groups: [.weather: weather], satellites: statuses, transmitters: transmitters,
                                               overrides: try TransmitterOverrides.bundled())
        let m24 = try #require(records.first { $0.elements.noradID == 59051 })
        #expect(m24.primaryTransmitter?.kind == .lrpt)
        #expect(m24.strength == .medium)
        let m23 = try #require(records.first { $0.elements.noradID == 57166 })
        #expect(m23.strength == .weak && m23.note != nil)
        // NOAA 21's only in-range downlinks are not decodable here, so it has no primary transmitter.
        let noaa21 = try #require(records.first { $0.elements.noradID == 54234 })
        #expect(noaa21.primaryTransmitter == nil)
    }

    @Test func suppressedTransmittersAreNotListedOrChosen() {
        let overrides = TransmitterOverrides(strengths: [:], notes: [:], verified: [],
                                             suppressed: [.init(noradID: 1, downlinkHz: 1_227_600_000, reason: "GPS receive frequency")])
        let transmitters = [transmitter("gps", norad: 1, mhz: 1227.6, mode: "FM"), transmitter("real", norad: 1, mhz: 137.1),
                            transmitter("otherSat", norad: 2, mhz: 1227.6, mode: "FM")]
        let records = SatelliteDirectory.build(groups: [.stations: [elements(1), elements(2)]], satellites: [:], transmitters: transmitters, overrides: overrides)
        #expect(records.first { $0.elements.noradID == 1 }?.transmitters.map(\.id) == ["real"])
        #expect(records.first { $0.elements.noradID == 2 }?.transmitters.map(\.id) == ["otherSat"], "only the named satellite is affected")
    }

    @Test func bundledOverridesDropNOAA20sGPSFrequencies() throws {
        let overrides = try TransmitterOverrides.bundled()
        #expect(overrides.isSuppressed(noradID: 43013, downlinkHz: 1_227_600_000))
        #expect(overrides.isSuppressed(noradID: 43013, downlinkHz: 1_575_420_000))
        #expect(!overrides.isSuppressed(noradID: 43013, downlinkHz: 1_544_500_000))
        #expect(!overrides.isSuppressed(noradID: 59051, downlinkHz: 1_227_600_000))
    }
}

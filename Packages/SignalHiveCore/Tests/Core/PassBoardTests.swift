import Testing
import Foundation
@testable import SignalHiveCore

/// Records built the way the app builds them, from the saved feed samples.
func sampleRecords() throws -> [SatelliteRecord] {
    let weather = try ElementParser.parseOMMJSON(try Fixtures.data("celestrak-weather-sample.json")).elements
    let transmitters = try TransmitterStore.parseTransmitters(try Fixtures.data("satnogs-transmitters-sample.json")).transmitters
    let statuses = try TransmitterStore.parseSatellites(try Fixtures.data("satnogs-satellites-sample.json")).statuses
    return SatelliteDirectory.build(groups: [.weather: weather], satellites: statuses, transmitters: transmitters,
                                    overrides: try TransmitterOverrides.bundled())
}

/// A satellite that decays 51.5 minutes after its epoch (verification-set case 28872), re-dated to a given epoch, with
/// an observer standing under its track at minute 20 (found for that epoch, since Earth's orientation depends on the
/// date) so a pass finishes before the decay.
private func decayingRecord(epoch: Date, noradID: Int = 28872) throws -> (record: SatelliteRecord, observer: Observer) {
    let source = try #require(try OracleCase.load().first { $0.name == "ver-28872" })
    var elements = source.elements
    elements.epoch = epoch
    elements.noradID = noradID
    elements.name = "DECAYING"
    let moment = epoch.addingTimeInterval(20 * 60)
    let under = GroundTrack.subpoint(of: try SGP4Propagator(elements).state(at: moment), at: moment).coordinate
    let record = SatelliteRecord(elements: elements, category: .weather, status: .alive,
                                 transmitters: [TransmitterInfo(id: "d", noradID: noradID, summary: "test", downlinkHz: 137.1e6, mode: "LRPT",
                                                                kind: .lrpt, isActive: true, service: nil, verifiedOnAir: nil)],
                                 strength: .strong, note: nil)
    return (record, Observer(under))
}

struct PassBoardTests {
    private let owner = Observer(latitudeDegrees: 35.2534, longitudeDegrees: -109.4374, altitudeMeters: 1800)

    @Test func ratesAndSortsPasses() throws {
        let records = try sampleRecords()
        let epoch = try #require(records.first { $0.elements.noradID == 59051 }).elements.epoch
        let result = PassBoard.compute(records: records, observer: owner, antennas: AntennaProfile.presets, from: epoch,
                                       horizon: 48 * 3600, minimumElevationDegrees: 5, now: epoch)
        #expect(!result.passes.isEmpty)
        #expect(result.passes.map(\.pass.aos) == result.passes.map(\.pass.aos).sorted())
        let meteor24 = result.passes.filter { $0.pass.noradID == 59051 }
        let meteor23 = result.passes.filter { $0.pass.noradID == 57166 }
        #expect(!meteor24.isEmpty && !meteor23.isEmpty)
        // The mast kit's telescopic mast covers 137 MHz, so Meteor passes are receivable and carry their reasons.
        #expect(meteor24.allSatisfy { $0.rating.grade > .notReceivable && !$0.rating.reasons.isEmpty })
        #expect(meteor24.allSatisfy { $0.transmitter?.kind == .lrpt && $0.confidence == .good })
        // NOAA 21 has no downlink this dongle can use: its passes are listed, rated not receivable, with the reason.
        let noaa = result.passes.filter { $0.pass.noradID == 54234 }
        #expect(!noaa.isEmpty && noaa.allSatisfy { $0.rating.grade == .notReceivable && $0.rating.reasons.contains("No known active downlink") })
        #expect(result.problems.isEmpty)
        // The weak Meteor never outranks the medium one on a pass of equal peak elevation: compare score per elevation.
        let m24Best = try #require(meteor24.max { $0.pass.maxElevationDegrees < $1.pass.maxElevationDegrees })
        let m23Same = meteor23.min { abs($0.pass.maxElevationDegrees - m24Best.pass.maxElevationDegrees) < abs($1.pass.maxElevationDegrees - m24Best.pass.maxElevationDegrees) }!
        #expect(m23Same.rating.reasons.contains { $0.contains("weak") })
    }

    @Test func oneBadSatelliteDoesNotBreakTheRest() throws {
        let records = try sampleRecords()
        let epoch = try #require(records.first { $0.elements.noradID == 59051 }).elements.epoch
        let decaying = try decayingRecord(epoch: epoch)
        let good = records.filter { $0.elements.noradID == 59051 }
        let result = PassBoard.compute(records: good + [decaying.record], observer: decaying.observer, antennas: AntennaProfile.presets,
                                       from: epoch, horizon: 24 * 3600, minimumElevationDegrees: 5, now: epoch)
        let problem = try #require(result.problems.first { $0.noradID == decaying.record.id })
        #expect(problem.message.lowercased().contains("decay"), "message: \(problem.message)")
        #expect(result.passes.contains { $0.pass.noradID == 59051 }, "the healthy satellite's passes are still there")
        let beforeDecay = result.passes.filter { $0.pass.noradID == decaying.record.id }
        #expect(beforeDecay.count == 1, "the pass that finished before the decay is kept")
        #expect(beforeDecay.first!.pass.los < epoch.addingTimeInterval(51.5 * 60))
        #expect(result.problems.count == 1)
    }

    @Test func unusableElementsBecomeAProblemNotAPass() throws {
        let records = try sampleRecords()
        let epoch = try #require(records.first { $0.elements.noradID == 59051 }).elements.epoch
        let now = epoch.addingTimeInterval(40 * 86_400)
        let result = PassBoard.compute(records: records, observer: owner, antennas: AntennaProfile.presets, from: now,
                                       horizon: 48 * 3600, minimumElevationDegrees: 5, now: now)
        #expect(result.passes.isEmpty)
        #expect(result.problems.count == records.count)
        #expect(result.problems.allSatisfy { $0.message.contains("40 days") }, "messages: \(result.problems.map(\.message))")
    }

    @Test func elementsFromTheFutureAreAProblemToo() throws {
        let records = try sampleRecords()
        let epoch = try #require(records.first { $0.elements.noradID == 59051 }).elements.epoch
        let now = epoch.addingTimeInterval(-3 * 86_400)
        let result = PassBoard.compute(records: records, observer: owner, antennas: AntennaProfile.presets, from: now,
                                       horizon: 48 * 3600, minimumElevationDegrees: 5, now: now)
        #expect(result.passes.isEmpty)
        #expect(result.problems.allSatisfy { $0.message.lowercased().contains("future") })
    }

    @Test func geostationarySatellitesAreSkippedAndCountedNotReportedAsProblems() throws {
        var geo = try #require(try OracleCase.load().first { $0.name == "ver-26900" }).elements
        geo.epoch = Date(timeIntervalSince1970: 1_790_000_000)
        let record = SatelliteRecord(elements: geo, category: .weather, status: .alive, transmitters: [], strength: .unknown, note: nil)
        let result = PassBoard.compute(records: [record], observer: owner, antennas: AntennaProfile.presets, from: geo.epoch,
                                       horizon: 24 * 3600, minimumElevationDegrees: 5, now: geo.epoch)
        #expect(result.passes.isEmpty && result.problems.isEmpty)
        #expect(result.deepSpaceSkipped == 1)
    }

    @Test func emptyRecordsGiveEmptyResult() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let result = PassBoard.compute(records: [], observer: owner, antennas: [], from: now, horizon: 86_400,
                                       minimumElevationDegrees: 5, now: now)
        #expect(result.passes.isEmpty && result.problems.isEmpty && result.deepSpaceSkipped == 0)
    }

    @Test func noAntennasMakesEverythingNotReceivableButStillListsThePasses() throws {
        let records = try sampleRecords()
        let epoch = try #require(records.first { $0.elements.noradID == 59051 }).elements.epoch
        let result = PassBoard.compute(records: records, observer: owner, antennas: [], from: epoch, horizon: 48 * 3600,
                                       minimumElevationDegrees: 5, now: epoch)
        #expect(!result.passes.isEmpty)
        #expect(result.passes.allSatisfy { $0.rating.grade == .notReceivable })
    }
}

#if canImport(RTLSDRDecoders)
import Testing
import Foundation
@testable import SignalHiveCore

/// Real frames from the sample recording shipped with dump978 (Oliver Jowett, GPL-2.0-or-later), taken in the San
/// Francisco Bay Area. The expected values are what dump978's own decoder prints for each frame; the decoder package tests
/// its side of that, so these tests check that the app turns the decoded fields into the right aircraft, radar and text.
struct UAT978PipelineTests {
    /// A basic (18-byte) downlink from aircraft A66EF1: position, altitude and velocity, no flight ID.
    private static let basicDownlink = "-00a66ef135445d525a0c0519119021204800;"
    /// A long downlink from the same aircraft: emitter category 2 and flight ID N5130E.
    private static let flightIDDownlink = "-08a66ef1353e2d525fd4050911882aa038101d06b85d440be2a4c2a0000590000000;rs=2;"
    /// A long downlink from the same aircraft a little later: it sends its squawk, 0322, instead.
    private static let squawkDownlink = "-08a66ef1353ae55263ac04f9117c2ba03f0c830cf5ed2d0bbaa4c0a0000590000000;"
    /// A ground-station uplink carrying two NOTAM records, two special-use-airspace records and a winds-aloft text report.
    private static let windsUplink = "+3514c952d65ca7b0158000210de09082102d30cb00082f0d1e012d30cb000000000000000fd900011710120118173ba9c9635e4c00158000210e9e0082102cf04b00082f521e012cf04b000000000000000fd900011a0f00011f0001a916435a6800278000350e1d682210000000ff004491387c4d5060cb4c74d35833d75db9c337f2d38df87d07d27f3cb0ca030f5dfc75c31cb4c74d357f1d70c72d70c73c1fc30c1fc78c1f05f65f7f3cb0c8c3d77df780288000350e1d682210000000ff004691347c4d5060cb4c74d35833d75db9c317f2d70db37d07d27f3cb0ca02091c87f1d70c72d31d34d5fc75c31cb5c31cf07f1e307f2e707c17d97dfcf2c322091c87df78002d00067408605c93844e0083160cb5c30c306a080651c5f1cb0c30707c78c30c1c0f2d30c30703cf0c30c1c133d30c30820cf9c30c1c65e718cf5cb2af0c20cf6cf1b71ce0c31d31b72de0c33d70d36830d36db5da0cf6d72d7879d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;"
    /// A ground-station uplink carrying NEXRAD radar blocks (regional product, all clear).
    private static let radarUplink = "+3514c952d65ca3b0040000fc10a0037fe400040000fc10a00381a510040000fc10a0042c2730040000fc10a003852930040000fc10a0038c3170040000fc10a0039a41f0040000fc10a0039c03f0040000fc10a0038df370040000fc10a0039dc5f0040000fc10a0039f87f0040000fc10a00386eb30040000fc10a0038fb570040000fc10a003a149f0040000fc10a003a30bf0040000fc10a003917770040000fc10a004235cf0040000fc10a004251ef0040000fc10a003836730040000fc10a00388ad70040000fc10a0039339f0040000fc10a00426e0f0040000fc10a00428a270040000fc10a0042a6530040000fc10a0042de910040000fc10a00394fbf0040000fc10a0038a6f70040000fc10a00396bdf0040000fc10a003987ff0048000fc10a003fe70f10f048000fc10a003fcaef10f048000fc10a003faecf10f048000fc10a003f92af10f048000fc10a003f768f10f048000fc10a003f5a7f107048000fc10a003f3e5f107048000fc10a003f223f107048000fc10a003f061f103048000fc10a003ee9ff103048000fc10a003ecddf103048000fc10a003eb1bf103048000fc10a003e959f10300;"

    private let now = Date(timeIntervalSinceReferenceDate: 6_000_000)

    private func aircraftReports(_ updates: [AviationUpdate]) -> [AircraftReport] {
        updates.compactMap { update in
            if case let .aircraft(report) = update { return report }
            return nil
        }
    }

    @Test func aBasicDownlinkGivesPositionAltitudeAndVelocity() throws {
        let pipeline = UATPipeline()
        #expect(pipeline.ingest(dump978Line: Self.basicDownlink, now: now))
        let report = try #require(aircraftReports(pipeline.drain()).first)
        #expect(report.address == 0xA66EF1)
        #expect(report.source == .uat)
        let position = try #require(report.coordinate)
        #expect(abs(position.latitude - 37.453380) < 1e-5 && abs(position.longitude - -122.096429) < 1e-5)
        #expect(report.altitudeFeet == 1_000)
        #expect(report.groundSpeedKnots == 118)
        #expect(report.trackDegrees == 146)
        #expect(report.verticalRateFPM == -192)
        #expect(report.onGround == false)
        #expect(report.callsign == nil && report.aircraftClass == nil)
    }

    @Test func aLongDownlinkAddsTheFlightIDAndTheCategory() throws {
        let pipeline = UATPipeline()
        pipeline.ingest(dump978Line: Self.flightIDDownlink, now: now)
        let report = try #require(aircraftReports(pipeline.drain()).first)
        #expect(report.callsign == "N5130E" && report.squawk == nil)
        #expect(report.aircraftClass == .small)
        #expect(report.altitudeFeet == 975, "the barometric altitude is used, not the 1,200 ft geometric one")
        #expect(report.groundSpeedKnots == 128 && report.trackDegrees == 139 && report.verticalRateFPM == -128)
        #expect(report.emergency == ADSBEmergencyState.none)
    }

    @Test func aDownlinkThatSendsASquawkIsNotMistakenForAFlightID() throws {
        let pipeline = UATPipeline()
        pipeline.ingest(dump978Line: Self.squawkDownlink, now: now)
        let report = try #require(aircraftReports(pipeline.drain()).first)
        #expect(report.squawk == "0322" && report.callsign == nil)
    }

    @Test func downlinksFromOneAircraftMergeAndFlowIntoThePicture() throws {
        let pipeline = UATPipeline()
        pipeline.ingest(dump978Line: Self.flightIDDownlink, now: now)
        pipeline.ingest(dump978Line: Self.squawkDownlink, now: now.addingTimeInterval(1))
        let updates = pipeline.drain()
        #expect(aircraftReports(updates).count == 1, "reports for one aircraft are merged")

        var picture = AviationPicture()
        picture.apply(updates)
        let state = try #require(picture.aircraft[0xA66EF1])
        #expect(state.callsign == "N5130E" && state.squawk == "0322")
        #expect(state.aircraftClass == .small && !state.classIsInferred)
        #expect(state.sources == [.uat])
        #expect(state.coordinate != nil && state.history.samples.count == 1)
    }

    @Test func anUplinkGivesAGroundStationAndTheWindsReport() throws {
        let pipeline = UATPipeline()
        #expect(pipeline.ingest(dump978Line: Self.windsUplink, now: now))
        let updates = pipeline.drain()

        var stations: [GroundStation] = []
        var messages: [AviationMessage] = []
        for update in updates {
            switch update {
            case let .groundStation(station): stations.append(station)
            case let .message(message): messages.append(message)
            default: break
            }
        }
        let station = try #require(stations.first)
        #expect(abs(station.coordinate.latitude - 37.322702) < 1e-4 && abs(station.coordinate.longitude - -121.754994) < 1e-4)
        #expect(station.slotID == 7)

        let winds = try #require(messages.first)
        #expect(messages.count == 1)
        #expect(winds.kind == .windsAloft)
        #expect(winds.station == "BCE")
        #expect(winds.body.hasPrefix("WINDS BCE 250000Z"))
        #expect(winds.origin == "FIS-B 978")

        let counters = pipeline.currentCounters
        #expect(counters.uplinks == 1 && counters.textReports == 1)
        #expect(counters.otherProducts.values.reduce(0, +) == 4, "two NOTAM and two airspace records are counted, not shown")
    }

    @Test func radarBlocksAreConvertedToTheMapsGrid() throws {
        let pipeline = UATPipeline()
        pipeline.ingest(dump978Line: Self.radarUplink, now: now)
        let blocks: [RadarBlock] = pipeline.drain().compactMap { update in
            if case let .radar(block, _) = update { return block }
            return nil
        }
        #expect(blocks.count > 10)
        #expect(pipeline.currentCounters.radarBlocks == blocks.count)
        for block in blocks {
            #expect(block.product == .regional)
            #expect(block.bins.count == 128)
            #expect(block.northArcminutes % 4 == 0 && block.westArcminutes % 48 == 0)
            #expect(block.heightArcminutes == 4 && block.widthArcminutes == 48)
            // Near the ground station (37.3 N, 121.8 W); longitudes are signed, so west is negative.
            #expect((1_800...3_000).contains(block.northArcminutes))
            #expect((-8_000 ... -6_500).contains(block.westArcminutes))
            #expect(block.hours == 4 && block.minutes == 10)
        }
    }

    @Test func radarBlocksBuildAMosaicAndAPicture() throws {
        let pipeline = UATPipeline()
        pipeline.ingest(dump978Line: Self.radarUplink, now: now)
        var picture = AviationPicture()
        picture.apply(pipeline.drain())
        let mosaic = try #require(picture.radar[.regional])
        #expect(mosaic.blockCount > 10 && mosaic.blockCount <= picture.stats.radarBlocks)
        #expect(mosaic.latestObservationLabel == "04:10Z")
        #expect(mosaic.raster() != nil)
    }

    @Test(arguments: ["", "hello", "-zz;", "+00;", "-00a66ef1;"])
    func textThatIsNotAFrameIsRefused(line: String) {
        let pipeline = UATPipeline()
        #expect(!pipeline.ingest(dump978Line: line, now: now))
        #expect(pipeline.drain().isEmpty)
    }

    @Test func silenceProducesNoFrames() {
        let pipeline = UATPipeline()
        let block = [UInt8](repeating: 127, count: 65_536)
        block.withUnsafeBufferPointer { pipeline.process($0, now: now) }
        #expect(pipeline.health.blocks == 1 && pipeline.health.frames == 0)
        #expect(pipeline.drain().isEmpty)
    }

    @Test func repairedFramesAreCounted() {
        let pipeline = UATPipeline()
        pipeline.ingest(dump978Line: Self.basicDownlink, now: now)
        pipeline.ingest(dump978Line: Self.flightIDDownlink, now: now)        // carries rs=2
        let counters = pipeline.currentCounters
        #expect(counters.frames == 2 && counters.downlinks == 2 && counters.repairedFrames == 1)
    }
}
#endif

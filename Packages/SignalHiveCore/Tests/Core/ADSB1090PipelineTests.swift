#if canImport(RTLSDRDecoders)
import Testing
import Foundation
@testable import SignalHiveCore

/// The frames are the published examples from Junzi Sun's "The 1090 MHz Riddle", the same ones the driver package
/// tests its decoder with.
struct ADSB1090PipelineTests {
    private static let identification = "8D4840D6202CC371C32CE0576098"      // KLM1023
    private static let evenPosition = "8D40621D58C382D690C8AC2863A7"
    private static let oddPosition = "8D40621D58C386435CC412692AD6"
    private static let groundVelocity = "8D485020994409940838175B284F"
    private static let airVelocity = "8DA05F219B06B6AF189400CBC33F"

    private let now = Date(timeIntervalSinceReferenceDate: 5_000_000)

    private func onlyReport(_ pipeline: ModeSPipeline) throws -> AircraftReport {
        let updates = pipeline.drain()
        try #require(updates.count == 1, "expected one merged report, got \(updates.count)")
        guard case let .aircraft(report) = updates[0] else {
            Issue.record("not an aircraft report")
            throw CancellationError()
        }
        return report
    }

    @Test func anIdentificationCarriesTheFlightID() throws {
        let pipeline = ModeSPipeline(receiver: nil)
        #expect(pipeline.ingest(hex: Self.identification, now: now, uptime: 1))
        let report = try onlyReport(pipeline)
        #expect(report.address == 0x4840D6)
        #expect(report.callsign == "KLM1023")
        #expect(report.source == .modeS)
        // Type code 4, category 0 is "no category information", so the app guesses from the flight ID instead.
        #expect(report.aircraftClass == .unknown)
        #expect(report.coordinate == nil)
    }

    @Test func aPairOfPositionFixesGivesAPosition() throws {
        let pipeline = ModeSPipeline(receiver: nil)
        pipeline.ingest(hex: Self.oddPosition, now: now, uptime: 0)
        let first = try onlyReport(pipeline)
        #expect(first.coordinate == nil, "one fix cannot be placed without a reference")
        #expect(first.altitudeFeet == 38_000 && first.onGround == false)

        pipeline.ingest(hex: Self.evenPosition, now: now.addingTimeInterval(2), uptime: 2)
        let second = try onlyReport(pipeline)
        let position = try #require(second.coordinate)
        #expect(abs(position.latitude - 52.2572021484375) < 1e-6)
        #expect(abs(position.longitude - 3.91937255859375) < 1e-6)
        #expect(second.address == 0x40621D)
    }

    @Test func aKnownReceiverLocationPlacesTheFirstFix() throws {
        let pipeline = ModeSPipeline(receiver: GeoCoordinate(latitude: 52.258, longitude: 3.918))
        pipeline.ingest(hex: Self.evenPosition, now: now, uptime: 0)
        let position = try #require(try onlyReport(pipeline).coordinate)
        #expect(abs(position.latitude - 52.2572021484375) < 1e-6)
    }

    @Test func messagesBetweenDrainsMergeIntoOneReport() throws {
        let pipeline = ModeSPipeline(receiver: nil)
        pipeline.ingest(hex: Self.oddPosition, now: now, uptime: 0)
        pipeline.ingest(hex: Self.evenPosition, now: now.addingTimeInterval(1), uptime: 1)
        let report = try onlyReport(pipeline)
        #expect(report.coordinate != nil)
        #expect(report.altitudeFeet == 38_000)
        #expect(report.time == now.addingTimeInterval(1))
        #expect(pipeline.drain().isEmpty, "draining empties the pipeline")
    }

    @Test func groundVelocityGivesSpeedTrackAndClimbRate() throws {
        let pipeline = ModeSPipeline(receiver: nil)
        pipeline.ingest(hex: Self.groundVelocity, now: now, uptime: 0)
        let report = try onlyReport(pipeline)
        #expect(report.address == 0x485020)
        #expect(abs((report.groundSpeedKnots ?? 0) - 159.2) < 0.01)
        #expect(abs((report.trackDegrees ?? 0) - 182.88) < 0.01)
        #expect(report.verticalRateFPM == -832)
    }

    @Test func airVelocityFallsBackToAirspeedAndHeading() throws {
        let pipeline = ModeSPipeline(receiver: nil)
        pipeline.ingest(hex: Self.airVelocity, now: now, uptime: 0)
        let report = try onlyReport(pipeline)
        #expect(report.groundSpeedKnots == 375)
        #expect(report.trackDegrees == 243.984375)
        #expect(report.verticalRateFPM == -2_304)
    }

    @Test func reportsFlowIntoThePictureWithAnInferredClassAndATrail() throws {
        let pipeline = ModeSPipeline(receiver: nil)
        var picture = AviationPicture()
        pipeline.ingest(hex: Self.identification, now: now, uptime: 0)
        picture.apply(pipeline.drain())
        let state = try #require(picture.aircraft[0x4840D6])
        #expect(state.callsign == "KLM1023")
        #expect(state.aircraftClass == .large && state.classIsInferred)
        #expect(state.country == "Netherlands")
    }

    @Test(arguments: ["", "zz", "8D4840D6", "8D4840D6202CC371C32CE0576098AA", "8D4840D6202CC371C32CE057609"])
    func textThatIsNotAWholeFrameIsRefused(hex: String) {
        let pipeline = ModeSPipeline(receiver: nil)
        #expect(!pipeline.ingest(hex: hex, now: now, uptime: 0))
        #expect(pipeline.drain().isEmpty)
    }

    @Test func aShortFrameOfTheRightLengthIsAccepted() {
        // DF11 (all-call reply) is 7 bytes.
        let pipeline = ModeSPipeline(receiver: nil)
        #expect(pipeline.ingest(hex: "5D4840D6EB5E6A", now: now, uptime: 0))
    }

    @Test func healthStartsEmpty() {
        let health = ModeSPipeline(receiver: nil).health
        #expect(health.blocks == 0 && health.frames == 0 && health.lastBlockAt == nil)
    }

    @Test func silenceProducesNoFrames() {
        let pipeline = ModeSPipeline(receiver: nil)
        let block = [UInt8](repeating: 127, count: 65_536)
        block.withUnsafeBufferPointer { pipeline.process($0, now: now, uptime: 0) }
        #expect(pipeline.health.blocks == 1)
        #expect(pipeline.health.frames == 0)
        #expect(pipeline.drain().isEmpty)
    }
}
#endif

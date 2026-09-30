import Testing
import Foundation
@testable import SignalHiveCore

private let start = Date(timeIntervalSinceReferenceDate: 2_000_000)

private func report(_ address: UInt32 = 0xA00001, at seconds: Double = 0, source: AircraftSource = .modeS,
                    callsign: String? = nil, squawk: String? = nil, altitude: Int? = nil, lat: Double? = nil,
                    lon: Double? = nil, speed: Double? = nil, aircraftClass: AircraftClass? = nil,
                    emergency: ADSBEmergencyState? = nil) -> AircraftReport {
    AircraftReport(address: address, source: source, time: start.addingTimeInterval(seconds), callsign: callsign,
                   squawk: squawk, altitudeFeet: altitude,
                   coordinate: lat.flatMap { latitude in lon.map { GeoCoordinate(latitude: latitude, longitude: $0) } },
                   groundSpeedKnots: speed, aircraftClass: aircraftClass, emergency: emergency)
}

struct AviationPictureTests {
    @Test func reportsMergeIntoOneAircraft() throws {
        var picture = AviationPicture()
        picture.apply(report(callsign: "UAL123 "))
        picture.apply(report(at: 2, altitude: 30_000, lat: 40, lon: -100, speed: 450))

        #expect(picture.aircraft.count == 1)
        let state = try #require(picture.aircraft[0xA00001])
        #expect(state.callsign == "UAL123")
        #expect(state.altitudeFeet == 30_000)
        #expect(state.groundSpeedKnots == 450)
        #expect(state.coordinate == GeoCoordinate(latitude: 40, longitude: -100))
        #expect(state.history.samples.count == 1)
        #expect(state.history.samples.first?.altitudeFeet == 30_000)
        #expect(state.messageCount == 2)
        #expect(state.sources == [.modeS])
        #expect(state.addressHex == "A00001")
        #expect(picture.stats.messages == 2 && picture.stats.positions == 1)
    }

    @Test func reportsWithoutAPositionAddNoHistory() throws {
        var picture = AviationPicture()
        picture.apply(report(altitude: 12_000))
        let state = try #require(picture.aircraft[0xA00001])
        #expect(state.history.samples.isEmpty)
        #expect(state.coordinate == nil)
        #expect(picture.positionedAircraft.isEmpty)
    }

    @Test func movingAircraftBuildATrail() throws {
        var picture = AviationPicture()
        for step in 0..<10 {
            picture.apply(report(at: Double(step) * 5, altitude: 5_000 + step * 400, lat: 40 + Double(step) * 0.01, lon: -100))
        }
        let state = try #require(picture.aircraft[0xA00001])
        #expect(state.history.samples.count == 10)
        #expect(state.history.altitudeRange == 5_000...8_600)
        let trail = TrailBuilder.segments(from: state.history.samples, now: start.addingTimeInterval(45), window: 600)
        #expect(trail.count >= 9)
    }

    @Test func theClassIsGuessedUntilTheAircraftSaysWhatItIs() throws {
        var picture = AviationPicture()
        picture.apply(report(callsign: "UAL123"))
        var state = try #require(picture.aircraft[0xA00001])
        #expect(state.aircraftClass == .large && state.classIsInferred)

        picture.apply(report(at: 1, aircraftClass: .heavy))
        state = try #require(picture.aircraft[0xA00001])
        #expect(state.aircraftClass == .heavy && !state.classIsInferred)

        picture.apply(report(at: 2, callsign: "UAL123", altitude: 30_000))
        state = try #require(picture.aircraft[0xA00001])
        #expect(state.aircraftClass == .heavy && !state.classIsInferred)
    }

    @Test func aircraftWithNothingToGoOnStayUnknown() throws {
        var picture = AviationPicture()
        picture.apply(report(altitude: 3_000, lat: 40, lon: -100, speed: 90))
        let state = try #require(picture.aircraft[0xA00001])
        #expect(state.aircraftClass == .unknown)
        #expect(state.iconKind == .unknown)
    }

    @Test func surfaceVehiclesAreOnTheGround() throws {
        var picture = AviationPicture()
        picture.apply(report(altitude: 0, lat: 40, lon: -100, aircraftClass: .surfaceService))
        let state = try #require(picture.aircraft[0xA00001])
        #expect(state.onGround)
        #expect(state.color == AltitudeColorScale.onGroundColor)
    }

    @Test func staleAircraftExpire() {
        var picture = AviationPicture()
        picture.apply(report(0xA00001, at: 0, lat: 40, lon: -100))
        picture.apply(report(0xA00002, at: 200, lat: 41, lon: -100))
        picture.expire(now: start.addingTimeInterval(250), aircraftTimeout: 120)
        #expect(picture.aircraft.count == 1)
        #expect(picture.aircraft[0xA00002] != nil)
    }

    @Test func expiryTrimsTrailsAndDropsOldRadar() throws {
        var picture = AviationPicture()
        picture.apply(report(at: 0, altitude: 5_000, lat: 40, lon: -100))
        picture.apply(report(at: 400, altitude: 5_000, lat: 40.1, lon: -100))
        picture.apply(.radar(RadarBlock(product: .regional, hours: 1, minutes: 0, northArcminutes: 2_400, westArcminutes: -7_200,
                                        heightArcminutes: 4, widthArcminutes: 48, bins: [UInt8](repeating: 3, count: 128)),
                             receivedAt: start))
        picture.expire(now: start.addingTimeInterval(500), aircraftTimeout: 600, trailAge: 300, radarAge: 300)
        let state = try #require(picture.aircraft[0xA00001])
        #expect(state.history.samples.count == 1)
        #expect(picture.radar.isEmpty)
    }

    @Test func anEmergencySquawkRaisesOneAlert() {
        var picture = AviationPicture()
        picture.apply(report(callsign: "N66ZK", squawk: "7700", altitude: 4_000, lat: 40, lon: -100))
        picture.apply(report(at: 1, squawk: "7700", lat: 40.001, lon: -100))
        let alerts = picture.messages.messages.filter { $0.kind == .aircraftAlert }
        #expect(alerts.count == 1)
        #expect(alerts.first?.severity == .critical)
        #expect(picture.emergencyAircraft.count == 1)
        #expect(alerts.first?.body.contains("N66ZK") == true)
    }

    @Test func aDeclaredEmergencyIsAlsoAnAlert() {
        var picture = AviationPicture()
        picture.apply(report(callsign: "MEDEVAC1", emergency: .lifeguardMedical))
        #expect(picture.messages.messages.contains { $0.kind == .aircraftAlert && $0.severity == .critical })
        // "No emergency" clears it.
        picture.apply(report(at: 5, emergency: ADSBEmergencyState.none))
        #expect(picture.emergencyAircraft.isEmpty)
    }

    @Test func radioFailureIsAWarningNotCritical() {
        var picture = AviationPicture()
        picture.apply(report(squawk: "7600"))
        #expect(picture.messages.messages.first?.severity == .warning)
    }

    @Test func rangeIsMeasuredFromTheReceiver() throws {
        var picture = AviationPicture(receiver: GeoCoordinate(latitude: 40, longitude: -100))
        picture.apply(report(lat: 41, lon: -100))
        let state = try #require(picture.aircraft[0xA00001])
        #expect(abs((picture.rangeNM(of: state) ?? 0) - 60.04) < 0.1)
        #expect(abs(picture.stats.farthestNM - 60.04) < 0.1)
        #expect(AviationPicture().rangeNM(of: state) == nil)
    }

    @Test func radarBlocksBuildAMosaicPerProduct() {
        var picture = AviationPicture()
        let bins = [UInt8](repeating: 3, count: 128)
        picture.apply(.radar(RadarBlock(product: .regional, hours: 1, minutes: 5, northArcminutes: 2_400, westArcminutes: -7_200,
                                        heightArcminutes: 4, widthArcminutes: 48, bins: bins), receivedAt: start))
        picture.apply(.radar(RadarBlock(product: .conus, hours: 1, minutes: 5, scale: 2, northArcminutes: 2_400, westArcminutes: -7_200,
                                        heightArcminutes: 36, widthArcminutes: 432, bins: bins), receivedAt: start))
        #expect(picture.radar[.regional]?.blockCount == 1)
        #expect(picture.radar[.conus]?.blockCount == 1)
        #expect(picture.stats.radarBlocks == 2)
    }

    @Test func groundStationsAreCountedNotDuplicated() {
        var picture = AviationPicture()
        let station = GroundStation(coordinate: GeoCoordinate(latitude: 40, longitude: -100), slotID: 3, heard: start)
        picture.apply(.groundStation(station))
        picture.apply(.groundStation(GroundStation(coordinate: station.coordinate, slotID: 4, heard: start.addingTimeInterval(30))))
        #expect(picture.groundStations.count == 1)
        #expect(picture.groundStations.values.first?.uplinks == 2)
        #expect(picture.groundStations.values.first?.slotID == 4)
    }

    @Test func clearingEmptiesEverything() {
        var picture = AviationPicture()
        picture.apply(report(lat: 40, lon: -100))
        picture.apply(.message(AviationMessage.fisbReport("METAR KSFO 300756Z 28008KT 10SM FEW015 15/12 A3002", at: start)))
        picture.clear()
        #expect(picture.aircraft.isEmpty && picture.messages.messages.isEmpty)
        #expect(picture.stats == AviationStats())
    }

    @Test func mergedReportsKeepTheNewestValuesAndTime() {
        var combined = report(at: 1, callsign: "AAA1", altitude: 1_000)
        combined.merge(report(at: 3, altitude: 2_000, lat: 40, lon: -100))
        combined.merge(report(at: 2, squawk: "1200"))
        #expect(combined.callsign == "AAA1")
        #expect(combined.altitudeFeet == 2_000)
        #expect(combined.squawk == "1200")
        #expect(combined.coordinate != nil)
        #expect(combined.time == start.addingTimeInterval(3))
    }

    @Test func freshnessAgesWithSilence() throws {
        var picture = AviationPicture()
        picture.apply(report(lat: 40, lon: -100))
        let state = try #require(picture.aircraft[0xA00001])
        #expect(state.freshness(now: start.addingTimeInterval(5)) == .live)
        #expect(state.freshness(now: start.addingTimeInterval(20)) == .recent)
        #expect(state.freshness(now: start.addingTimeInterval(60)) == .stale)
    }

    @Test func icaoBlocksNameCountries() {
        #expect(ICAOAddressBlocks.country(for: 0xA12345) == "United States")
        #expect(ICAOAddressBlocks.country(for: 0x400001) == "United Kingdom")
        #expect(ICAOAddressBlocks.country(for: 0xC01234) == "Canada")
        #expect(ICAOAddressBlocks.country(for: 0x000001) == nil)
        #expect(ICAOAddressBlocks.isUSMilitary(0xAE1234))
        #expect(!ICAOAddressBlocks.isUSMilitary(0xA12345))
    }

    @Test func squawkAlertsAreRecognised() {
        #expect(SquawkAlert(squawk: "7500") == .hijack)
        #expect(SquawkAlert(squawk: "7600") == .radioFailure)
        #expect(SquawkAlert(squawk: "7700") == .emergency)
        #expect(SquawkAlert(squawk: "1200") == nil)
    }
}

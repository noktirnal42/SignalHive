import Testing
import Foundation
@testable import SignalHiveCore

private let t0 = Date(timeIntervalSinceReferenceDate: 4_000_000)
private let receiver = GeoCoordinate(latitude: 40, longitude: -100)

private func fix(_ address: UInt32, callsign: String? = nil, squawk: String? = nil, altitude: Int? = nil,
                 lat: Double? = nil, lon: Double? = nil, speed: Double? = nil, onGround: Bool? = nil,
                 source: AircraftSource = .modeS, emergency: ADSBEmergencyState? = nil) -> AircraftReport {
    AircraftReport(address: address, source: source, time: t0, callsign: callsign, squawk: squawk, altitudeFeet: altitude,
                   coordinate: lat.flatMap { latitude in lon.map { GeoCoordinate(latitude: latitude, longitude: $0) } },
                   groundSpeedKnots: speed, onGround: onGround, emergency: emergency)
}

private func metar(_ text: String, at seconds: Double = 0) -> AviationUpdate {
    .message(.fisbReport(text, at: t0.addingTimeInterval(seconds)))
}

/// UAL100 is the highest, fastest and farthest; TUG1 is on the ground; the fourth has no position.
private func trafficPicture() -> AviationPicture {
    var picture = AviationPicture(receiver: receiver)
    picture.apply(fix(0xA1, callsign: "UAL100", altitude: 37_000, lat: 41, lon: -100, speed: 480, onGround: false))
    picture.apply(fix(0xA2, callsign: "DAL200", altitude: 12_000, lat: 40.5, lon: -100, speed: 250, onGround: false))
    picture.apply(fix(0xA3, callsign: "TUG1", lat: 40.01, lon: -100, speed: 12, onGround: true))
    picture.apply(fix(0xA4, altitude: 5_000, speed: 150, onGround: false, source: .uat))
    return picture
}

private func weatherPicture() -> AviationPicture {
    var picture = AviationPicture()
    picture.apply(metar("METAR KJFK 011651Z 18016G26KT 1 1/2SM -RA BR BKN008 OVC015 12/11 A2985"))
    picture.apply(metar("METAR KSFO 011656Z 28008KT 10SM FEW015 15/12 A3002"))
    picture.apply(metar("METAR KDFW 011653Z 20012KT 3SM +TSRA BKN020CB 24/22 A2990"))
    return picture
}

struct AviationBriefingTests {
    // MARK: Nothing heard

    @Test func anEmptyPictureSaysNothingWasHeard() {
        let briefing = AviationBriefing.make(from: AviationPicture(), now: t0)

        #expect(briefing.isEmpty)
        #expect(briefing.headline == "Nothing heard yet.")
        #expect(briefing.lines == ["No aircraft or reports heard yet. Start a receiver in Air Map or Air Data."])
    }

    // MARK: Traffic

    @Test func trafficIsCountedByWhatItIsDoing() {
        let traffic = AviationBriefing.make(from: trafficPicture(), now: t0).traffic

        #expect(traffic.tracked == 4)
        #expect(traffic.airborne == 3)
        #expect(traffic.onGround == 1)
        #expect(traffic.withPosition == 3)
    }

    @Test func theExtremesAreTakenFromAirborneAircraftOnly() throws {
        let traffic = AviationBriefing.make(from: trafficPicture(), now: t0).traffic

        #expect(try #require(traffic.highest).name == "UAL100")
        #expect(try #require(traffic.highest).value == 37_000)
        #expect(try #require(traffic.fastest).name == "UAL100")
        #expect(try #require(traffic.fastest).value == 480, "the 12 kt taxiing vehicle is not the fastest, and not airborne either")
        let farthest = try #require(traffic.farthest)
        #expect(farthest.name == "UAL100")
        #expect(abs(farthest.value - 60) < 0.5)
    }

    @Test func withoutAReceiverLocationThereIsNoFarthest() {
        var picture = trafficPicture()
        picture.receiver = nil

        #expect(AviationBriefing.make(from: picture, now: t0).traffic.farthest == nil)
    }

    @Test func eachSourceReportsHowManyAircraftItHeard() {
        let traffic = AviationBriefing.make(from: trafficPicture(), now: t0).traffic

        #expect(traffic.bySource == ["ADS-B 1090": 3, "UAT 978": 1])
    }

    @Test func theTrafficLinesReadLikeAnAirTrafficSummary() {
        let lines = AviationBriefing.make(from: trafficPicture(), now: t0).lines

        #expect(lines.contains("4 aircraft tracked: 3 airborne, 1 on the ground, 3 with a position."))
        #expect(lines.contains("Heard on: ADS-B 1090 3, UAT 978 1."))
        #expect(lines.contains("Highest: UAL100 at FL370."))
        #expect(lines.contains("Fastest: UAL100 at 480 kt."))
        #expect(lines.contains("Farthest: UAL100 at 60.0 NM."))
    }

    @Test func aircraftNotHeardForTwoMinutesAreNotTracked() {
        // A stopped receiver leaves its last picture behind; the briefing must not call that live traffic.
        let briefing = AviationBriefing.make(from: trafficPicture(), now: t0.addingTimeInterval(600))

        #expect(briefing.traffic.tracked == 0)
        #expect(briefing.emergencies.isEmpty)
        #expect(briefing.lines.contains("No aircraft currently tracked.") == false, "nothing at all was held, so the empty message applies")
        #expect(briefing.headline == "Nothing heard yet.")
    }

    // MARK: Emergencies

    @Test func emergenciesNameTheAircraftAndTheReason() {
        var picture = trafficPicture()
        picture.apply(fix(0xB1, callsign: "N911", squawk: "7700", altitude: 4_000, lat: 40.2, lon: -100.1, speed: 110))
        picture.apply(fix(0xB2, callsign: "DAL5", altitude: 30_000, speed: 400, emergency: .minimumFuel))
        let briefing = AviationBriefing.make(from: picture, now: t0)

        #expect(briefing.emergencies == [
            AviationBriefing.Emergency(name: "DAL5", reason: "Minimum Fuel"),
            AviationBriefing.Emergency(name: "N911", reason: "Squawk 7700 (emergency)"),
        ])
        #expect(briefing.headline == "2 aircraft declaring an emergency: DAL5, N911.")
        #expect(briefing.lines.first == "EMERGENCY: DAL5 — Minimum Fuel")
        #expect(briefing.lines.contains("EMERGENCY: N911 — Squawk 7700 (emergency)"))
    }

    @Test func noEmergencyMeansNoEmergencyLines() {
        let briefing = AviationBriefing.make(from: trafficPicture(), now: t0)

        #expect(briefing.emergencies.isEmpty)
        #expect(!briefing.lines.contains { $0.hasPrefix("EMERGENCY") })
    }

    // MARK: Weather

    @Test func weatherIsSummarisedByFlightCategory() throws {
        let weather = AviationBriefing.make(from: weatherPicture(), now: t0).weather

        #expect(weather.stations == 3)
        #expect(weather.byCategory[.vfr] == 1)
        #expect(weather.byCategory[.mvfr] == 1)
        #expect(weather.byCategory[.ifr] == 1)
        #expect(weather.worstCategory == .ifr)
        #expect(weather.worstStations == ["KJFK"])
        #expect(weather.thunderstormStations == ["KDFW"])
        #expect(try #require(weather.lowestCeiling).station == "KJFK")
        #expect(try #require(weather.lowestCeiling).feet == 800)
        #expect(try #require(weather.strongestWind).station == "KJFK")
        #expect(try #require(weather.strongestWind).knots == 26)
    }

    @Test func onlyTheNewestReportForAStationCounts() {
        var picture = AviationPicture()
        picture.apply(metar("METAR KJFK 011651Z 18016G26KT 1 1/2SM -RA BR BKN008 OVC015 12/11 A2985", at: 0))
        picture.apply(metar("METAR KJFK 011751Z 18008KT 10SM FEW050 15/10 A2990", at: 600))
        let weather = AviationBriefing.make(from: picture, now: t0).weather

        #expect(weather.stations == 1)
        #expect(weather.worstCategory == .vfr)
        #expect(weather.lowestCeiling == nil)
    }

    @Test func theWeatherLinesNameTheWorstStationsAndTheHazards() {
        let lines = AviationBriefing.make(from: weatherPicture(), now: t0).lines

        #expect(lines.contains("Weather: 3 stations (1 VFR, 1 MVFR, 1 IFR). Worst: KJFK IFR."))
        #expect(lines.contains("Thunderstorms reported at KDFW."))
        #expect(lines.contains("Lowest ceiling: 800 ft at KJFK."))
        #expect(lines.contains("Strongest wind: 26 kt (gust) at KJFK."))
    }

    @Test func theHeadlineLeadsWithTheWorstWeatherWhenThereIsNoEmergency() {
        var picture = trafficPicture()
        picture.apply(metar("METAR KJFK 011651Z 18016G26KT 1 1/2SM -RA BR BKN008 OVC015 12/11 A2985"))
        picture.apply(metar("METAR KSFO 011656Z 28008KT 10SM FEW015 15/12 A3002"))

        #expect(AviationBriefing.make(from: picture, now: t0).headline == "4 aircraft tracked; worst weather IFR at KJFK.")
    }

    @Test func clearWeatherIsSaidPlainly() {
        var picture = AviationPicture()
        picture.apply(metar("METAR KSFO 011656Z 28008KT 10SM FEW015 15/12 A3002"))

        #expect(AviationBriefing.make(from: picture, now: t0).headline == "1 weather station; all stations VFR.")
    }

    // MARK: Hazard products

    @Test func hazardProductsAreCountedAndTheUrgentOnesListed() {
        var picture = AviationPicture()
        picture.apply(metar("SIGMET NOVEMBER 3 VALID UNTIL 302100", at: 0))
        picture.apply(metar("AIRMET SIERRA UPDT 3", at: 1))
        picture.apply(metar("NOTAM-TFR KSFO 3NM RADIUS", at: 2))
        picture.apply(metar("NOTAM-D KSFO RWY 10L CLSD", at: 3))
        let briefing = AviationBriefing.make(from: picture, now: t0)
        let titles = picture.messages.messages.reduce(into: [AviationMessageKind: String]()) { $0[$1.kind] = $1.title }

        #expect(briefing.hazards.sigmets == 1)
        #expect(briefing.hazards.airmets == 1)
        #expect(briefing.hazards.restrictions == 1)
        #expect(briefing.hazards.advisories == 0)
        #expect(briefing.hazards.urgent == [titles[.restriction]!, titles[.sigmet]!], "newest first, warnings and above only")
        #expect(briefing.lines.contains("Active products: 1 SIGMET, 1 AIRMET, 1 TFR / SUA."))
        #expect(briefing.lines.contains("Urgent: \(titles[.sigmet]!)"))
    }

    @Test func aircraftAlertsAreNotRepeatedAsHazards() {
        var picture = AviationPicture()
        picture.apply(fix(0xB1, callsign: "N911", squawk: "7700", altitude: 4_000))
        let briefing = AviationBriefing.make(from: picture, now: t0)

        #expect(briefing.hazards.urgent.isEmpty, "the emergency is already its own section")
        #expect(briefing.emergencies.count == 1)
    }
}

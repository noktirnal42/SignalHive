import Testing
import Foundation
@testable import SignalHiveCore

struct AviationDemoScenarioTests {
    private let center = GeoCoordinate(latitude: 39.1, longitude: -94.6)
    private let moment = Date(timeIntervalSinceReferenceDate: 780_000_000)

    @Test func theSkyIsBusyAndCoversTheAircraftClasses() {
        let picture = AviationDemoScenario(center: center).snapshot(at: moment)
        #expect(picture.aircraft.count == AviationDemoScenario.flightCount)
        #expect(picture.aircraft.count >= 25)
        let classes = Set(picture.aircraft.values.map(\.aircraftClass))
        #expect(classes.count >= 17, "the demo should show off the icons")
        let kinds = Set(picture.aircraft.values.map(\.iconKind))
        #expect(kinds.contains(.bizjet) && kinds.contains(.small))
        #expect(picture.receiver == center)
    }

    @Test func everyAircraftHasAValidPositionNearTheCentre() {
        let picture = AviationDemoScenario(center: center).snapshot(at: moment)
        for state in picture.aircraft.values {
            let position = state.coordinate
            #expect(position?.isValid == true, "\(state.displayName) has no valid position")
            if let position {
                #expect(GeoMath.distanceNM(center, position) < 250, "\(state.displayName) strayed too far")
            }
        }
    }

    @Test func everyAircraftCarriesATrailWithAltitude() {
        let picture = AviationDemoScenario(center: center).snapshot(at: moment)
        for state in picture.aircraft.values where !state.onGround {
            #expect(state.history.samples.count > 20, "\(state.displayName) has almost no history")
        }
        let climbing = picture.aircraft.values.filter { ($0.history.altitudeRange.map { $0.upperBound - $0.lowerBound } ?? 0) > 3_000 }
        #expect(climbing.count >= 10, "several trails should show a visible climb or descent")
    }

    @Test func trailsShowAColorGradient() throws {
        let picture = AviationDemoScenario(center: center).snapshot(at: moment)
        let state = try #require(picture.aircraft.values.first { $0.callsign == "SWA1207" })
        let pieces = TrailBuilder.segments(from: state.history.samples, now: moment, window: 15 * 60)
        #expect(pieces.count > 30)
        #expect(Set(pieces.map(\.color)).count > 10, "an aircraft that climbs and descends should pass through many colors")
    }

    @Test func theSameMomentGivesTheSamePicture() {
        let scenario = AviationDemoScenario(center: center)
        #expect(scenario.snapshot(at: moment) == scenario.snapshot(at: moment))
    }

    @Test func aircraftMoveAsTimePasses() throws {
        let scenario = AviationDemoScenario(center: center)
        let before = scenario.snapshot(at: moment)
        let after = scenario.snapshot(at: moment.addingTimeInterval(60))
        let a = try #require(before.aircraft.values.first { $0.callsign == "UAL482" }?.coordinate)
        let b = try #require(after.aircraft.values.first { $0.callsign == "UAL482" }?.coordinate)
        let flown = GeoMath.distanceNM(a, b)
        // An airliner at about 450 knots covers about 7.5 NM a minute.
        #expect(flown > 5 && flown < 10, "flew \(flown) NM")
    }

    @Test func reportedGroundSpeedMatchesTheDistanceActuallyFlown() throws {
        let scenario = AviationDemoScenario(center: center)
        let state = try #require(scenario.snapshot(at: moment).aircraft.values.first { $0.callsign == "AAL233" })
        let next = try #require(scenario.snapshot(at: moment.addingTimeInterval(10)).aircraft.values.first { $0.callsign == "AAL233" }?.coordinate)
        let coordinate = try #require(state.coordinate)
        let knots = GeoMath.distanceNM(coordinate, next) * 360
        let reported = try #require(state.groundSpeedKnots)
        #expect(abs(knots - reported) < 15, "\(knots) kt flown against \(reported) kt reported")
    }

    @Test func thereAreEmergenciesForTheAlertPanel() {
        let picture = AviationDemoScenario(center: center).snapshot(at: moment)
        #expect(picture.emergencyAircraft.count >= 2)
        let alerts = picture.messages.messages.filter { $0.kind == .aircraftAlert }
        #expect(alerts.count == picture.emergencyAircraft.count)
        #expect(alerts.contains { $0.severity == .critical } && alerts.contains { $0.severity == .warning })
    }

    @Test func surfaceVehiclesStayOnTheGround() {
        let picture = AviationDemoScenario(center: center).snapshot(at: moment)
        let ground = picture.aircraft.values.filter { !$0.aircraftClass.isAircraft }
        #expect(ground.count >= 3)
        for state in ground {
            #expect(state.onGround && state.altitudeFeet == 0)
        }
    }

    @Test func radarHasStormsAndRastersToAPicture() throws {
        let scenario = AviationDemoScenario(center: center)
        let blocks = scenario.radarBlocks(at: moment)
        #expect(blocks.count > 20)
        #expect(blocks.allSatisfy { $0.bins.count == 128 && $0.product == .regional })
        #expect(blocks.contains { $0.peakLevel >= 6 }, "the storm cores should reach the strong levels")
        let raster = try #require(RadarRasterizer.raster(from: blocks))
        #expect(raster.echoPixelCount > 500)
        #expect(raster.north > raster.south && raster.east > raster.west)
    }

    @Test func radarDriftsOverTime() {
        let scenario = AviationDemoScenario(center: center)
        let now = scenario.radarBlocks(at: moment)
        let later = scenario.radarBlocks(at: moment.addingTimeInterval(1_800))
        #expect(now != later)
    }

    @Test func blocksSitOnTheFISBGrid() {
        for block in AviationDemoScenario(center: center).radarBlocks(at: moment) {
            #expect(block.northArcminutes % 4 == 0)
            #expect(block.westArcminutes % 48 == 0)
            #expect(block.widthArcminutes == 48 && block.heightArcminutes == 4)
        }
    }

    @Test func theSampleReportsAllDecode() {
        let messages = AviationDemoScenario(center: center).messages(at: moment)
        #expect(messages.count >= 10)
        let kinds = Set(messages.map(\.kind))
        for kind in [AviationMessageKind.metar, .taf, .pirep, .sigmet, .airmet, .restriction, .windsAloft, .atis] {
            #expect(kinds.contains(kind), "missing a sample \(kind)")
        }
        let metars = messages.compactMap(\.observation)
        #expect(metars.count >= 4)
        let categories = Set(metars.map(\.flightCategory))
        #expect(categories.isSuperset(of: [.vfr, .mvfr, .ifr, .lifr]), "the samples should cover every flight category")
        #expect(messages.allSatisfy { $0.origin == "Demo" })
    }

    @Test func messageIdentitiesStayPutWhileTheClockRuns() {
        let scenario = AviationDemoScenario(center: center)
        let first = Set(scenario.snapshot(at: moment).messages.messages.map(\.id))
        let later = Set(scenario.snapshot(at: moment.addingTimeInterval(5)).messages.messages.map(\.id))
        #expect(first == later)
    }

    @Test func aFullSnapshotFeedsTheTextPanel() {
        let picture = AviationDemoScenario(center: center).snapshot(at: moment)
        #expect(picture.messages.messages.count >= 10)
        #expect(picture.groundStations.count == 1)
    }
}

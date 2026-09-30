import Testing
import Foundation
@testable import SignalHiveCore

struct GeoMathTests {
    @Test func oneDegreeOfLatitudeIsAboutSixtyNauticalMiles() {
        let distance = GeoMath.distanceNM(GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 1, longitude: 0))
        #expect(abs(distance - 60.04) < 0.05)
    }

    @Test func bearingsFollowTheCompass() {
        let origin = GeoCoordinate(latitude: 40, longitude: -100)
        #expect(abs(GeoMath.bearingDegrees(from: origin, to: GeoCoordinate(latitude: 41, longitude: -100)) - 0) < 0.01)
        #expect(abs(GeoMath.bearingDegrees(from: origin, to: GeoCoordinate(latitude: 39, longitude: -100)) - 180) < 0.01)
        let west = GeoMath.bearingDegrees(from: origin, to: GeoCoordinate(latitude: 40, longitude: -101))
        #expect(west > 269 && west < 271)
    }

    @Test func destinationInvertsDistanceAndBearing() {
        let start = GeoCoordinate(latitude: 35.2, longitude: -111.6)
        let end = GeoMath.destination(from: start, bearingDegrees: 47, distanceNM: 123)
        #expect(abs(GeoMath.distanceNM(start, end) - 123) < 0.01)
        #expect(abs(GeoMath.bearingDegrees(from: start, to: end) - 47) < 0.2)
    }

    @Test func longitudesWrapIntoRange() {
        #expect(GeoMath.normalizedLongitude(190) == -170)
        #expect(GeoMath.normalizedLongitude(-190) == 170)
        #expect(GeoMath.normalizedLongitude(45) == 45)
        #expect(GeoMath.normalizedLongitude(180) == 180)
    }

    @Test func mercatorRoundTripsAndClampsAtTheProjectionLimit() {
        for latitude in [-80.0, -45.0, 0.0, 12.5, 60.0, 84.0] {
            let y = GeoMath.mercatorY(latitude: latitude)
            #expect(abs(GeoMath.latitude(mercatorY: y) - latitude) < 1e-9)
        }
        #expect(GeoMath.mercatorY(latitude: 90).isFinite)
        #expect(abs(GeoMath.mercatorY(latitude: 0)) < 1e-12)
    }

    @Test(arguments: [
        ("40.1234, -100.5", 40.1234, -100.5), ("40.1234 -100.5", 40.1234, -100.5), ("  40.1234,-100.5 ", 40.1234, -100.5),
        ("40.1234 N 100.5 W", 40.1234, -100.5), ("40.1234N, 100.5W", 40.1234, -100.5), ("33.9 S 151.2 E", -33.9, 151.2),
        ("40.1234\u{00B0}, -100.5\u{00B0}", 40.1234, -100.5), ("100.5 W 40.1234 N", 40.1234, -100.5),
    ] as [(String, Double, Double)])
    func typedPositionsAreUnderstood(text: String, latitude: Double, longitude: Double) throws {
        let parsed = try #require(GeoCoordinate.parse(text))
        #expect(abs(parsed.latitude - latitude) < 1e-9 && abs(parsed.longitude - longitude) < 1e-9)
    }

    @Test(arguments: ["", "hello", "40", "40, 200", "95, 10", "40 50 60", "N N"])
    func nonsensePositionsAreRefused(text: String) {
        #expect(GeoCoordinate.parse(text) == nil)
    }

    @Test func invalidCoordinatesAreRejected() {
        #expect(!GeoCoordinate(latitude: 91, longitude: 0).isValid)
        #expect(!GeoCoordinate(latitude: 0, longitude: .nan).isValid)
        #expect(GeoCoordinate(latitude: -90, longitude: 180).isValid)
    }
}

struct AltitudeColorScaleTests {
    @Test func stopsReturnTheirOwnColors() {
        for stop in AltitudeColorScale.stops {
            #expect(AltitudeColorScale.color(forFeet: Double(stop.feet)) == stop.color)
        }
    }

    @Test func colorsBlendBetweenStops() {
        // Halfway between 0 ft (255, 90, 60) and 1,000 ft (255, 130, 40).
        #expect(AltitudeColorScale.color(forFeet: 500) == RGB8(255, 110, 50))
    }

    @Test func endsAreClamped() {
        #expect(AltitudeColorScale.color(forFeet: -1_000) == AltitudeColorScale.stops.first?.color)
        #expect(AltitudeColorScale.color(forFeet: 80_000) == AltitudeColorScale.stops.last?.color)
    }

    @Test func groundAndUnknownHaveTheirOwnColors() {
        #expect(AltitudeColorScale.color(altitudeFeet: 35_000, onGround: true) == AltitudeColorScale.onGroundColor)
        #expect(AltitudeColorScale.color(altitudeFeet: nil) == AltitudeColorScale.unknownColor)
        #expect(AltitudeColorScale.color(altitudeFeet: 35_000) != AltitudeColorScale.unknownColor)
    }

    @Test func stopsAreOrderedSoTheRampIsWellDefined() {
        let feet = AltitudeColorScale.stops.map(\.feet)
        #expect(feet == feet.sorted())
        #expect(Set(feet).count == feet.count)
    }

    @Test func tonesDarkenAndLighten() {
        let color = RGB8(100, 200, 50)
        #expect(color.toned(0.5) == RGB8(50, 100, 25))
        #expect(color.toned(1) == color)
        let lighter = color.toned(1.5)
        #expect(lighter.red > color.red && lighter.green > color.green && lighter.blue > color.blue)
    }

    @Test func legendFractionsSpanTheBar() {
        #expect(AltitudeColorScale.legendFraction(feet: 0) == 0)
        #expect(AltitudeColorScale.legendFraction(feet: AltitudeColorScale.maximumFeet) == 1)
        #expect(AltitudeColorScale.legendFraction(feet: 100_000) == 1)
    }
}

struct AircraftClassTests {
    static let adsbCases: [(Int, Int, AircraftClass)] = [
        (4, 1, .light), (4, 2, .small), (4, 3, .large), (4, 4, .highVortexLarge), (4, 5, .heavy),
        (4, 6, .highPerformance), (4, 7, .rotorcraft), (3, 1, .glider), (3, 2, .lighterThanAir), (3, 3, .parachutist),
        (3, 4, .ultralight), (3, 6, .uav), (3, 7, .spaceVehicle), (2, 1, .surfaceEmergency), (2, 2, .surfaceService),
        (2, 3, .pointObstacle), (2, 4, .clusterObstacle), (2, 5, .lineObstacle), (4, 0, .unknown), (1, 3, .unknown),
    ]

    @Test(arguments: AircraftClassTests.adsbCases)
    func adsbCategoriesMapToClasses(typeCode: Int, category: Int, expected: AircraftClass) {
        #expect(AircraftClass.fromADSB(typeCode: typeCode, category: category) == expected)
    }

    static let uatCases: [(Int, AircraftClass)] = [
        (1, .light), (3, .large), (5, .heavy), (7, .rotorcraft), (9, .glider), (10, .lighterThanAir),
        (14, .uav), (17, .surfaceEmergency), (21, .lineObstacle), (0, .unknown), (8, .unknown), (39, .unknown),
    ]

    @Test(arguments: AircraftClassTests.uatCases)
    func uatCategoriesMapToClasses(category: Int, expected: AircraftClass) {
        #expect(AircraftClass.fromUAT(emitterCategory: category) == expected)
    }

    @Test func classesAreInferredFromFlightIDsAndSpeed() {
        #expect(AircraftClass.inferred(callsign: "UAL123", groundSpeedKnots: nil, altitudeFeet: nil) == .large)
        #expect(AircraftClass.inferred(callsign: "DAL1901 ", groundSpeedKnots: nil, altitudeFeet: nil) == .large)
        #expect(AircraftClass.inferred(callsign: "N123AB", groundSpeedKnots: nil, altitudeFeet: nil) == .light)
        #expect(AircraftClass.inferred(callsign: nil, groundSpeedKnots: 430, altitudeFeet: 36_000) == .large)
        #expect(AircraftClass.inferred(callsign: nil, groundSpeedKnots: 100, altitudeFeet: 3_000) == .unknown)
        #expect(AircraftClass.inferred(callsign: "", groundSpeedKnots: nil, altitudeFeet: nil) == .unknown)
        // Not an airline ID: too few letters, or no digits.
        #expect(AircraftClass.inferred(callsign: "AB12", groundSpeedKnots: nil, altitudeFeet: nil) == .unknown)
        #expect(AircraftClass.inferred(callsign: "LIFEGUARD", groundSpeedKnots: nil, altitudeFeet: nil) == .unknown)
    }

    @Test func smallAircraftAreDrawnByHowTheyFly() {
        #expect(AircraftIconKind(class: .small, groundSpeedKnots: 180, altitudeFeet: 9_000) == .small)
        #expect(AircraftIconKind(class: .small, groundSpeedKnots: 380, altitudeFeet: 9_000) == .bizjet)
        #expect(AircraftIconKind(class: .small, groundSpeedKnots: nil, altitudeFeet: 41_000) == .bizjet)
        #expect(AircraftIconKind(class: .heavy) == .heavy)
    }

    @Test func everyClassHasAnIcon() {
        for aircraftClass in AircraftClass.allCases {
            #expect(!AircraftIconKind(class: aircraftClass).parts.isEmpty, "no icon for \(aircraftClass)")
        }
    }

    @Test func onlySurfaceThingsAreNotAircraft() {
        let notAircraft = AircraftClass.allCases.filter { !$0.isAircraft }
        #expect(Set(notAircraft) == [.surfaceEmergency, .surfaceService, .pointObstacle, .clusterObstacle, .lineObstacle])
    }
}

struct AircraftIconDataTests {
    @Test func everyIconKindHasGeometry() {
        for kind in AircraftIconKind.allCases {
            #expect(!kind.parts.isEmpty, "\(kind) has no parts")
            #expect(kind.parts.contains { $0.paint == .body }, "\(kind) has no body")
        }
    }

    @Test func geometryStaysInsideTheUnitSquare() {
        for kind in AircraftIconKind.allCases {
            for part in kind.parts {
                switch part.shape {
                case let .polygon(xy):
                    #expect(xy.count >= 6 && xy.count % 2 == 0, "\(kind): a polygon needs whole vertices")
                    #expect(xy.allSatisfy { $0.isFinite && abs($0) <= 1.05 }, "\(kind): vertex outside the icon")
                case let .ellipse(cx, cy, rx, ry):
                    #expect(rx > 0 && ry > 0)
                    #expect(abs(cx) + rx <= 1.05 && abs(cy) + ry <= 1.05, "\(kind): ellipse outside the icon")
                case let .line(x1, y1, x2, y2, width):
                    #expect([x1, y1, x2, y2].allSatisfy { $0.isFinite && abs($0) <= 1.05 })
                    #expect(width > 0 && width < 0.3)
                }
            }
        }
    }

    @Test func generatedTableCoversEveryKind() {
        #expect(Set(AircraftIconData.parts.keys) == Set(AircraftIconKind.allCases.map(\.rawValue)))
    }
}

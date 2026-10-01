import Foundation
import Testing
@testable import SignalHiveCore

struct SatellitePassPlannerTests {
    private let iss = """
    ISS (ZARYA)
    1 25544U 98067A   25273.56282970  .00013982  00000+0  25353-3 0  9991
    2 25544  51.6311 178.9253 0004254  36.7694 323.3591 15.50035835533355
    """

    @Test func parsesThreeLineElements() throws {
        let satellites = TLEParser.parseMany(iss)
        let satellite = try #require(satellites.first)

        #expect(satellite.name == "ISS (ZARYA)")
        #expect(satellite.noradID == 25544)
        #expect(abs(satellite.inclinationDegrees - 51.6311) < 0.0001)
        #expect(abs(satellite.eccentricity - 0.0004254) < 0.0000001)
        #expect(satellite.meanMotionRevsPerDay > 15)
    }

    @Test func findsVisiblePassesFromObserverLocation() throws {
        let satellite = try #require(TLEParser.parseMany(iss).first)
        let start = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0), year: 2025, month: 9, day: 30, hour: 0)))
        let planner = SatellitePassPlanner(minimumElevationDegrees: 3, sampleInterval: 60)
        let passes = planner.upcomingPasses(for: [satellite], observer: GeoCoordinate(latitude: 35.2, longitude: -111.65),
                                            from: start, through: start.addingTimeInterval(24 * 3600))

        #expect(!passes.isEmpty)
        #expect(passes.allSatisfy { $0.maxElevationDegrees >= 3 })
        #expect(passes.allSatisfy { $0.start <= $0.peak && $0.peak <= $0.end })
        #expect(passes.allSatisfy { $0.peakAzimuthDegrees >= 0 && $0.peakAzimuthDegrees < 360 })
    }

    @Test func invalidObserverProducesNoPasses() throws {
        let satellite = try #require(TLEParser.parseMany(iss).first)
        let planner = SatellitePassPlanner()
        let passes = planner.upcomingPasses(for: [satellite], observer: GeoCoordinate(latitude: 120, longitude: 0),
                                            from: Date(), through: Date().addingTimeInterval(3600))
        #expect(passes.isEmpty)
    }
}

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

    @Test func captureRecipePadsThePassAndChoosesMeteorLRPT() throws {
        var satellite = try #require(TLEParser.parseMany(iss).first)
        satellite.name = "METEOR-M 2-3"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pass = SatellitePass(satellite: satellite, start: start, peak: start.addingTimeInterval(300),
                                 end: start.addingTimeInterval(620), maxElevationDegrees: 44,
                                 peakAzimuthDegrees: 210, peakRangeKM: 980,
                                 peakSubsatellite: GeoCoordinate(latitude: 32, longitude: -118))

        let recipe = try #require(SatelliteCaptureRecipe.make(for: pass, padding: 90))

        #expect(recipe.mode == .meteorLRPT)
        #expect(recipe.downlinkFrequencyHz == 137_900_000)
        #expect(recipe.sampleRateHz == 288_000)
        #expect(recipe.captureStart == start.addingTimeInterval(-90))
        #expect(recipe.captureEnd == start.addingTimeInterval(710))
        #expect(recipe.dopplerCorrectionEnabled)
    }

    @Test func meteorDownlinkFollowsTheSatelliteWhateverTheCatalogSpellsIt() throws {
        // CelesTrak says "METEOR-M2 4"; older element sets say "METEOR-M N2-4". M2-4 is on 137.1 MHz, M2-3 on 137.9.
        for (name, hz) in [("METEOR-M2 4", 137_100_000.0), ("METEOR-M 2-4", 137_100_000), ("METEOR-M N2-4", 137_100_000),
                           ("METEOR-M2 3", 137_900_000), ("METEOR-M 2-3", 137_900_000)] {
            var satellite = try #require(TLEParser.parseMany(iss).first)
            satellite.name = name
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let pass = SatellitePass(satellite: satellite, start: start, peak: start.addingTimeInterval(300),
                                     end: start.addingTimeInterval(600), maxElevationDegrees: 40,
                                     peakAzimuthDegrees: 90, peakRangeKM: 900,
                                     peakSubsatellite: GeoCoordinate(latitude: 0, longitude: 0))
            #expect(SatelliteCaptureRecipe.make(for: pass)?.downlinkFrequencyHz == hz, "\(name)")
        }
    }

    @Test func satellitesAnRTLSDRCannotReceiveGetNoCaptureRecipe() throws {
        // X-band polar orbiters, geostationary relays and a dead Meteor are in CelesTrak's weather group but are not
        // 137 MHz downlinks; the planner must not offer to capture them.
        for name in ["SUOMI NPP", "NOAA 20", "NOAA 21", "GOES 18", "FENGYUN 3D", "ISS (ZARYA)", "METEOR-M2 2"] {
            var satellite = try #require(TLEParser.parseMany(iss).first)
            satellite.name = name
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let pass = SatellitePass(satellite: satellite, start: start, peak: start.addingTimeInterval(300),
                                     end: start.addingTimeInterval(600), maxElevationDegrees: 60,
                                     peakAzimuthDegrees: 90, peakRangeKM: 900,
                                     peakSubsatellite: GeoCoordinate(latitude: 0, longitude: 0))
            #expect(SatelliteCaptureRecipe.make(for: pass) == nil, "\(name)")
        }
    }

    @Test func noaaCaptureRecipeUsesAptDefaults() throws {
        var satellite = try #require(TLEParser.parseMany(iss).first)
        satellite.name = "NOAA 18"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pass = SatellitePass(satellite: satellite, start: start, peak: start.addingTimeInterval(400),
                                 end: start.addingTimeInterval(800), maxElevationDegrees: 20,
                                 peakAzimuthDegrees: 180, peakRangeKM: 1_400,
                                 peakSubsatellite: GeoCoordinate(latitude: 12, longitude: -80))

        let recipe = try #require(SatelliteCaptureRecipe.make(for: pass))

        #expect(recipe.mode == .noaaAPT)
        #expect(recipe.downlinkFrequencyHz == 137_912_500)
        #expect(recipe.sampleRateHz == 48_000)
    }

    @Test func simulatedImageProductReflectsPassQuality() throws {
        var satellite = try #require(TLEParser.parseMany(iss).first)
        satellite.name = "METEOR-M 2-4"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lowPass = SatellitePass(satellite: satellite, start: start, peak: start.addingTimeInterval(400),
                                    end: start.addingTimeInterval(800), maxElevationDegrees: 12,
                                    peakAzimuthDegrees: 180, peakRangeKM: 1_900,
                                    peakSubsatellite: GeoCoordinate(latitude: 12, longitude: -80))
        let highPass = SatellitePass(satellite: satellite, start: start, peak: start.addingTimeInterval(400),
                                     end: start.addingTimeInterval(800), maxElevationDegrees: 72,
                                     peakAzimuthDegrees: 180, peakRangeKM: 620,
                                     peakSubsatellite: GeoCoordinate(latitude: 12, longitude: -80))

        let low = SatelliteImageProduct.simulated(from: try #require(.make(for: lowPass)), capturedAt: start)
        let high = SatelliteImageProduct.simulated(from: try #require(.make(for: highPass)), capturedAt: start)

        #expect(high.qualityScore > low.qualityScore)
        #expect(high.decodedLineCount > low.decodedLineCount)
        #expect(high.productName == "MSU-MR composite")
        #expect(high.isSimulated)
    }
}

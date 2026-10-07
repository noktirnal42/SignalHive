import Testing
import Foundation
@testable import SignalHiveCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// A pass whose track runs from azimuth 350 through north to 80 over 20 seconds, rising from 5 to 45 and back to 5.
private func syntheticPass(aos: Date = now) -> PredictedPass {
    let points: [(Double, Double, Double, Double)] = [
        (350, 5, 2000, 6.0), (355, 25, 1500, 3.0), (0, 45, 1000, 0.0), (40, 25, 1500, -3.0), (80, 5, 2000, -6.0),
    ]
    let track = points.enumerated().map { index, p in
        PassPoint(time: aos.addingTimeInterval(Double(index) * 5), azimuthDegrees: p.0, elevationDegrees: p.1, rangeKM: p.2, rangeRateKMPerSec: p.3)
    }
    return PredictedPass(id: "1-1", noradID: 1, satelliteName: "TEST", aos: aos, tca: aos.addingTimeInterval(10), los: aos.addingTimeInterval(20),
                         aosAzimuthDegrees: 350, tcaAzimuthDegrees: 0, losAzimuthDegrees: 80, maxElevationDegrees: 45, minRangeKM: 1000,
                         sunElevationAtTCADegrees: 0, sunlitAtTCA: true, startsBeforeWindow: false, endsAfterWindow: false,
                         elementEpoch: aos, track: track)
}

private func ratedPass(_ pass: PredictedPass, name: String? = nil) throws -> RatedPass {
    let record = SatelliteRecord(
        elements: OrbitalElements(name: name ?? pass.satelliteName, noradID: pass.noradID, epoch: pass.elementEpoch, inclinationDegrees: 98,
                                  raanDegrees: 0, eccentricity: 0.001, argumentOfPerigeeDegrees: 0, meanAnomalyDegrees: 0,
                                  meanMotionRevsPerDay: 14.2, bstar: 1e-5),
        category: .weather, status: .alive, transmitters: [], strength: .unknown, note: nil)
    return RatedPass(pass: pass, record: record, transmitter: nil,
                     rating: PassRating(grade: .good, score: 60, reasons: [], remedy: nil), confidence: .good)
}

struct PassViewModelTests {
    // MARK: Polar sky plot

    @Test func polarProjectionKeyPoints() {
        let zenith = PolarProjection.point(azimuthDegrees: 123, elevationDegrees: 90, radius: 100)
        #expect(abs(zenith.x) < 1e-9 && abs(zenith.y) < 1e-9)
        let north = PolarProjection.point(azimuthDegrees: 0, elevationDegrees: 0, radius: 100)
        #expect(abs(north.x) < 1e-9 && abs(north.y - 100) < 1e-9, "north is up")
        let east = PolarProjection.point(azimuthDegrees: 90, elevationDegrees: 0, radius: 100)
        #expect(abs(east.x - 100) < 1e-9 && abs(east.y) < 1e-9, "east is to the right")
        let south = PolarProjection.point(azimuthDegrees: 180, elevationDegrees: 0, radius: 100)
        #expect(abs(south.x) < 1e-9 && abs(south.y + 100) < 1e-9)
        let half = PolarProjection.point(azimuthDegrees: 0, elevationDegrees: 45, radius: 100)
        #expect(abs(half.y - 50) < 1e-9, "45 degrees up is half way to the centre")
        let below = PolarProjection.point(azimuthDegrees: 0, elevationDegrees: -10, radius: 100)
        #expect(abs(below.y - 100) < 1e-9, "below the horizon is drawn on the horizon ring")
    }

    // MARK: Ground track

    @Test func groundTrackSplitsAtTheAntimeridian() {
        let eastward = [GeoCoordinate(latitude: 0, longitude: 177), GeoCoordinate(latitude: 1, longitude: 179),
                        GeoCoordinate(latitude: 2, longitude: -179), GeoCoordinate(latitude: 3, longitude: -177)]
        let segments = GroundTrack.segments(eastward)
        #expect(segments.count == 2)
        #expect(segments[0].map(\.longitude) == [177, 179])
        #expect(segments[1].map(\.longitude) == [-179, -177])
        let westward = GroundTrack.segments(eastward.reversed())
        #expect(westward.count == 2)
        // A long run west (decreasing longitude) with no wrap is one segment.
        let plain = [10.0, 5, 0, -5, -10].map { GeoCoordinate(latitude: 0, longitude: $0) }
        #expect(GroundTrack.segments(plain).count == 1)
    }

    @Test func groundTrackWithNoJumpIsOneSegment() {
        #expect(GroundTrack.segments([]).isEmpty)
        let one = [GeoCoordinate(latitude: 1, longitude: 2)]
        #expect(GroundTrack.segments(one) == [one])
        let track = (0..<50).map { GeoCoordinate(latitude: Double($0), longitude: Double($0) * 3 - 90) }
        #expect(GroundTrack.segments(track).count == 1)
    }

    @Test func groundTrackPointsStayWithinTheInclinationAndCrossTheAntimeridianCleanly() throws {
        let iss = try #require(try OracleCase.load().first { $0.name == "iss-2025-09-30" }).elements
        let points = GroundTrack.points(elements: iss, from: iss.epoch, through: iss.epoch.addingTimeInterval(3 * 3600), step: 20)
        #expect(points.count > 500)
        #expect(points.allSatisfy { abs($0.latitude) <= 51.9 && $0.longitude >= -180 && $0.longitude <= 180 })
        let segments = GroundTrack.segments(points)
        #expect(segments.count >= 2, "three hours of an ISS track must cross the antimeridian")
        // No segment holds a jump of more than 180 degrees.
        for segment in segments {
            for (a, b) in zip(segment, segment.dropFirst()) { #expect(abs(b.longitude - a.longitude) < 180) }
        }
    }

    @Test func footprintRadiusForTheISS() {
        // 420 km up: the horizon is about 2254 km away along the ground.
        #expect(abs(GroundTrack.footprintRadiusKM(altitudeKM: 420) - 2253.7) < 0.5)
        #expect(GroundTrack.footprintRadiusKM(altitudeKM: 0) == 0)
    }

    // MARK: Timeline

    @Test func timelineLayoutAcrossLocalMidnightAndDSTIsMonotonicInUTC() throws {
        // US clocks fall back on 2026-11-01: a local day there is 25 hours in Los Angeles and still 24 in Phoenix.
        let from = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
        let through = from.addingTimeInterval(48 * 3600)
        let layout = TimelineLayout(passes: [], from: from, through: through)
        let width = 4800.0
        #expect(layout.x(for: from, width: width) == 0)
        #expect(abs(layout.x(for: through, width: width) - width) < 1e-9)
        #expect(abs(layout.x(for: from.addingTimeInterval(24 * 3600), width: width) - width / 2) < 1e-9)

        for zoneName in ["America/Phoenix", "America/Los_Angeles"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zoneName)!
            var midnights: [Date] = []
            calendar.enumerateDates(startingAfter: from, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) { date, _, stop in
                guard let date, date <= through else { stop = true; return }
                midnights.append(date)
            }
            #expect(midnights.count == 2, "\(zoneName): local midnights in the window")
            let xs = midnights.map { layout.x(for: $0, width: width) }
            #expect(xs == xs.sorted() && Set(xs).count == xs.count, "\(zoneName): strictly increasing")
            for (a, b) in zip(xs, xs.dropFirst()) {
                let hours = (b - a) / width * 48
                #expect(hours >= 23 - 1e-6 && hours <= 25 + 1e-6, "\(zoneName): \(hours) hours between local midnights")
            }
        }
        // Every hour of the window maps to a strictly larger x than the hour before.
        var previous = -1.0
        for hour in 0...48 {
            let x = layout.x(for: from.addingTimeInterval(Double(hour) * 3600), width: width)
            #expect(x > previous)
            previous = x
        }
    }

    @Test func timelineLanesGroupBySatellite() throws {
        let a1 = try ratedPass(syntheticPass(aos: now.addingTimeInterval(3600)), name: "ALPHA")
        var second = syntheticPass(aos: now.addingTimeInterval(600))
        second.noradID = 2
        second.satelliteName = "BETA"
        let b = try ratedPass(second, name: "BETA")
        var third = syntheticPass(aos: now.addingTimeInterval(9000))
        third.id = "1-2"
        let a2 = try ratedPass(third, name: "ALPHA")
        let layout = TimelineLayout(passes: [a1, b, a2], from: now, through: now.addingTimeInterval(48 * 3600))
        #expect(layout.lanes.count == 2)
        #expect(layout.lanes.map(\.name) == ["BETA", "ALPHA"], "lanes are ordered by their first pass")
        let alpha = try #require(layout.lanes.first { $0.name == "ALPHA" })
        #expect(alpha.passes.map(\.id) == ["1-1", "1-2"] || alpha.passes.count == 2)
        #expect(alpha.passes.map(\.pass.aos) == alpha.passes.map(\.pass.aos).sorted())
    }

    @Test func daylightRangesFollowTheSun() {
        let observer = Observer(latitudeDegrees: 35.25, longitudeDegrees: -109.44)
        let from = ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")!
        let through = from.addingTimeInterval(48 * 3600)
        let layout = TimelineLayout(passes: [], from: from, through: through, observer: observer)
        // Sun is up at the start (local late afternoon), then a full day, then a day cut off by the window end.
        #expect(layout.daylight.count == 3, "ranges: \(layout.daylight)")
        #expect(layout.daylight.first?.lowerBound == from)
        #expect(layout.daylight.last?.upperBound == through)
        for range in layout.daylight {
            #expect(range.lowerBound < range.upperBound)
        }
        for (a, b) in zip(layout.daylight, layout.daylight.dropFirst()) { #expect(a.upperBound < b.lowerBound) }
        // Spot checks against the sun itself, to the 5-minute step the ranges are built on.
        var moment = from
        while moment <= through {
            let up = SunPosition.elevationDegrees(from: observer, at: moment) > 0
            let inside = layout.daylight.contains { $0.contains(moment) }
            if abs(SunPosition.elevationDegrees(from: observer, at: moment)) > 1.5 { #expect(up == inside, "\(moment)") }
            moment.addTimeInterval(600)
        }
        #expect(TimelineLayout(passes: [], from: from, through: through).daylight.isEmpty, "no observer, no daylight shading")
    }

    // MARK: Pointing guide

    @Test func pointingGuideBeforeDuringAfter() throws {
        let pass = syntheticPass()
        let guide = PointingGuide(pass: pass)

        let before = guide.state(at: now.addingTimeInterval(-90))
        guard case let .beforeAOS(seconds) = before.phase else { Issue.record("expected beforeAOS, got \(before.phase)"); return }
        #expect(abs(seconds - 90) < 1e-9)
        #expect(before.azimuthDegrees == 350, "where to look for it to appear")
        #expect(before.elevationDegrees == nil)
        #expect(before.dopplerHz(carrierHz: 137.1e6) == nil)

        let during = guide.state(at: now.addingTimeInterval(7.5)) // half way between track[1] (355, 25) and track[2] (0, 45)
        guard case let .inPass(secondsToLOS) = during.phase else { Issue.record("expected inPass, got \(during.phase)"); return }
        #expect(abs(secondsToLOS - 12.5) < 1e-9)
        #expect(abs(try #require(during.elevationDegrees) - 35) < 1e-9)
        #expect(abs(try #require(during.azimuthDegrees) - 357.5) < 1e-9, "azimuth interpolates the short way across north")
        #expect(during.compass == "N")
        // Range-rate half way between +3 and 0 km/s is +1.5: receding, so the frequency is lower.
        let doppler = try #require(during.dopplerHz(carrierHz: 137.1e6))
        #expect(abs(doppler - Topocentric.dopplerShiftHz(carrierHz: 137.1e6, rangeRateKMPerSec: 1.5)) < 1e-6)
        #expect(doppler < 0)

        let atAOS = guide.state(at: now)
        guard case .inPass = atAOS.phase else { Issue.record("AOS itself is in the pass"); return }
        #expect(atAOS.elevationDegrees == 5)

        let after = guide.state(at: now.addingTimeInterval(21))
        guard case .after = after.phase else { Issue.record("expected after, got \(after.phase)"); return }
        #expect(after.azimuthDegrees == nil && after.elevationDegrees == nil)
        #expect(after.compass == "")
        #expect(after.dopplerHz(carrierHz: 137.1e6) == nil)
    }

    @Test(arguments: [(0.0, "N"), (45.0, "NE"), (350.0, "N"), (100.0, "E"), (22.5, "NNE"), (180.0, "S"), (270.0, "W"), (315.0, "NW"), (359.9, "N"), (-10.0, "N"), (360.0, "N")])
    func compassPoints(azimuth: Double, expected: String) {
        #expect(PointingGuide.compass(forAzimuth: azimuth) == expected)
    }
}

import Foundation

/// A made-up, always-moving sky for trying the map without an antenna: about thirty aircraft of every class on
/// looping paths that climb and descend (so trails show their altitude gradient), a line of storms drifting across as
/// radar, and a set of sample weather reports.
///
/// Everything is a pure function of the clock, so the picture is the same however often it is rebuilt, and tests can
/// ask for any moment. None of it is real: airports and reports use made-up identifiers, and the app labels the
/// source "Demo".
public struct AviationDemoScenario: Sendable {
    public let center: GeoCoordinate

    public init(center: GeoCoordinate) {
        self.center = center
    }

    // MARK: Flights

    struct Flight {
        var address: UInt32
        var callsign: String
        /// nil: the transponder sends no category (the app then guesses from the flight ID).
        var aircraftClass: AircraftClass?
        /// The centre of the flight's loop, relative to the scenario centre.
        var bearing: Double
        var distanceNM: Double
        var semiMajorNM: Double
        var semiMinorNM: Double
        var rotationDegrees: Double
        var clockwise: Bool
        var speedKnots: Double
        var phase: Double
        var baseAltitudeFeet: Double
        var swingFeet: Double
        var periodMinutes: Double
        var altitudePhase: Double
        var onGround = false
        var squawk = "1200"
        var emergency: ADSBEmergencyState?
    }

    struct Instant {
        var coordinate: GeoCoordinate
        var altitudeFeet: Int
        var groundSpeedKnots: Double
        var trackDegrees: Double?
        var verticalRateFPM: Int
    }

    private static let flights: [Flight] = {
        var list: [Flight] = []
        func add(_ callsign: String, _ cls: AircraftClass?, at bearing: Double, _ distance: Double, a: Double, b: Double,
                 rot: Double = 0, cw: Bool = true, kt: Double, phase: Double = 0, alt: Double, swing: Double = 0,
                 period: Double = 20, altPhase: Double = 0, ground: Bool = false, squawk: String = "1200",
                 emergency: ADSBEmergencyState? = nil) {
            let index = UInt32(list.count)
            list.append(Flight(address: 0xA1_0000 + index * 0x1_237, callsign: callsign, aircraftClass: cls, bearing: bearing,
                               distanceNM: distance, semiMajorNM: a, semiMinorNM: b, rotationDegrees: rot, clockwise: cw,
                               speedKnots: kt, phase: phase, baseAltitudeFeet: alt, swingFeet: swing, periodMinutes: period,
                               altitudePhase: altPhase, onGround: ground, squawk: squawk, emergency: emergency))
        }
        // Airliners: high and fast on wide loops, some climbing out or descending in.
        add("UAL482", .large, at: 20, 25, a: 70, b: 45, rot: 30, kt: 450, phase: 0.4, alt: 36_000, swing: 3_000, period: 40, squawk: "4521")
        add("DAL1901", .large, at: 200, 35, a: 60, b: 60, cw: false, kt: 430, phase: 2.0, alt: 31_000, swing: 9_000, period: 22, altPhase: 1.0, squawk: "2266")
        add("AAL233", .heavy, at: 100, 40, a: 90, b: 40, rot: -20, kt: 480, phase: 3.4, alt: 38_000, swing: 1_500, period: 50, squawk: "5104")
        add("SWA1207", .large, at: 300, 30, a: 40, b: 25, rot: 60, kt: 300, phase: 1.1, alt: 14_000, swing: 11_000, period: 18, altPhase: 2.2, squawk: "3011")
        add("FDX3310", .heavy, at: 160, 20, a: 55, b: 35, rot: 100, cw: false, kt: 420, phase: 5.0, alt: 34_000, swing: 6_000, period: 30, squawk: "6642")
        add("UPS991", .highVortexLarge, at: 250, 45, a: 50, b: 30, rot: 10, kt: 380, phase: 0.2, alt: 24_000, swing: 8_000, period: 26, altPhase: 3.0, squawk: "0442")
        add("JBU640", .large, at: 340, 55, a: 65, b: 65, kt: 440, phase: 4.2, alt: 37_000, swing: 2_000, period: 35, squawk: "1750")
        add("NKS58", .large, at: 60, 15, a: 30, b: 20, rot: 40, cw: false, kt: 260, phase: 2.6, alt: 8_000, swing: 6_500, period: 14, altPhase: 0.5, squawk: "3760")
        // Business jets and turboprops.
        add("EJA412", .small, at: 140, 50, a: 45, b: 30, rot: 75, kt: 410, phase: 1.7, alt: 41_000, swing: 1_000, period: 30, squawk: "5217")
        add("LXJ72", .small, at: 10, 60, a: 35, b: 20, rot: 5, cw: false, kt: 380, phase: 3.9, alt: 29_000, swing: 5_000, period: 20, squawk: "4400")
        add("N801DM", .small, at: 230, 12, a: 18, b: 12, rot: 15, kt: 210, phase: 0.9, alt: 12_000, swing: 3_500, period: 16, squawk: "0321")
        add("N77TP", .small, at: 320, 22, a: 15, b: 15, kt: 190, phase: 5.5, alt: 9_500, swing: 2_500, period: 12, altPhase: 1.5, squawk: "4715")
        // General aviation.
        add("N172SP", .light, at: 80, 6, a: 6, b: 6, kt: 95, phase: 0.0, alt: 3_500, swing: 700, period: 9, squawk: "1200")
        add("N4821Q", nil, at: 190, 10, a: 8, b: 5, rot: 25, cw: false, kt: 110, phase: 2.1, alt: 5_500, swing: 1_800, period: 11, squawk: "1200")
        add("N35PA", .light, at: 270, 8, a: 4, b: 4, kt: 85, phase: 4.4, alt: 2_400, swing: 500, period: 7, squawk: "1200")
        add("N9RJ", .light, at: 30, 14, a: 10, b: 7, rot: 70, kt: 120, phase: 1.3, alt: 7_500, swing: 1_200, period: 13, squawk: "1200")
        add("N208GP", .light, at: 350, 4, a: 3, b: 3, cw: false, kt: 80, phase: 3.0, alt: 1_800, swing: 300, period: 6, squawk: "7600", emergency: nil)
        add("N66ZK", .light, at: 120, 18, a: 5, b: 5, kt: 100, phase: 0.7, alt: 4_000, swing: 2_500, period: 5, altPhase: 2.4, squawk: "7700", emergency: .general)
        // Rotorcraft, glider, balloon, parachutist, drone, fighter.
        add("LIFE7", .rotorcraft, at: 210, 5, a: 3, b: 2, rot: 40, kt: 85, phase: 1.0, alt: 1_200, swing: 500, period: 8, squawk: "4433")
        add("N911PD", .rotorcraft, at: 40, 3, a: 2, b: 2, cw: false, kt: 60, phase: 2.8, alt: 800, swing: 250, period: 6, squawk: "5200")
        add("GLIDER", .glider, at: 290, 11, a: 4, b: 3, kt: 55, phase: 3.3, alt: 7_500, swing: 2_800, period: 10, altPhase: 0.3)
        add("BALLOON", .lighterThanAir, at: 155, 9, a: 3, b: 3, kt: 9, phase: 0.6, alt: 2_000, swing: 600, period: 30)
        add("SKYDIVE", .parachutist, at: 90, 2, a: 0.6, b: 0.6, kt: 22, phase: 2.0, alt: 6_000, swing: 5_500, period: 9, altPhase: 1.57)
        add("DRONE1", .uav, at: 235, 1.5, a: 0.4, b: 0.4, kt: 18, phase: 1.4, alt: 350, swing: 60, period: 3)
        add("VIPER1", .highPerformance, at: 5, 42, a: 28, b: 14, rot: 45, cw: false, kt: 440, phase: 4.0, alt: 24_000, swing: 4_000, period: 15, squawk: "4030")
        add("HANGGL", .ultralight, at: 300, 7, a: 2, b: 1.5, kt: 28, phase: 0.8, alt: 4_500, swing: 1_500, period: 7)
        // No flight ID and no category: the map draws it as an unknown.
        add("", nil, at: 130, 16, a: 9, b: 6, rot: 50, kt: 105, phase: 3.6, alt: 3_200, swing: 900, period: 8)
        // The airport: vehicles crawling about, and a tower that does not move.
        add("RESCUE1", .surfaceEmergency, at: 88, 0.6, a: 0.3, b: 0.15, kt: 14, phase: 0.5, alt: 0, ground: true, squawk: "0000")
        add("FUEL3", .surfaceService, at: 92, 0.7, a: 0.4, b: 0.2, rot: 30, cw: false, kt: 9, phase: 2.2, alt: 0, ground: true, squawk: "0000")
        add("TOWER", .pointObstacle, at: 95, 0.9, a: 0, b: 0, kt: 0, alt: 0, ground: true, squawk: "0000")
        add("CRANES", .clusterObstacle, at: 80, 1.4, a: 0, b: 0, kt: 0, alt: 0, ground: true, squawk: "0000")
        add("POWERLN", .lineObstacle, at: 110, 2.2, a: 0, b: 0, kt: 0, alt: 0, ground: true, squawk: "0000")
        return list
    }()

    func instant(of flight: Flight, at seconds: TimeInterval) -> Instant {
        let hours = seconds / 3_600
        let average = max(0.0001, (flight.semiMajorNM + flight.semiMinorNM) / 2)
        let omega = flight.speedKnots / average                       // radians per hour
        let direction = flight.clockwise ? -1.0 : 1.0
        let theta = flight.phase + direction * omega * hours

        let ex = flight.semiMajorNM * cos(theta)
        let ey = flight.semiMinorNM * sin(theta)
        let dex = -flight.semiMajorNM * sin(theta) * direction * omega     // nautical miles per hour
        let dey = flight.semiMinorNM * cos(theta) * direction * omega
        let rotation = flight.rotationDegrees * Double.pi / 180
        let x = ex * cos(rotation) - ey * sin(rotation)
        let y = ex * sin(rotation) + ey * cos(rotation)
        let dx = dex * cos(rotation) - dey * sin(rotation)
        let dy = dex * sin(rotation) + dey * cos(rotation)

        let loopCentre = GeoMath.destination(from: center, bearingDegrees: flight.bearing, distanceNM: flight.distanceNM)
        let latitude = loopCentre.latitude + y / 60
        let longitude = loopCentre.longitude + x / (60 * max(0.05, cos(loopCentre.latitude * Double.pi / 180)))

        let speed = (dx * dx + dy * dy).squareRoot()
        var track: Double?
        if speed > 0.5 {
            var degrees = atan2(dx, dy) * 180 / Double.pi
            if degrees < 0 { degrees += 360 }
            track = degrees
        }

        var altitude = flight.baseAltitudeFeet
        var rate = 0.0
        if flight.swingFeet > 0, flight.periodMinutes > 0 {
            let angular = 2 * Double.pi / (flight.periodMinutes * 60)
            altitude += flight.swingFeet * sin(angular * seconds + flight.altitudePhase)
            rate = flight.swingFeet * angular * cos(angular * seconds + flight.altitudePhase) * 60
        }
        if flight.onGround { altitude = 0; rate = 0 }
        return Instant(coordinate: GeoCoordinate(latitude: latitude, longitude: GeoMath.normalizedLongitude(longitude)),
                       altitudeFeet: max(0, Int(altitude.rounded())), groundSpeedKnots: speed, trackDegrees: track,
                       verticalRateFPM: Int(rate.rounded()))
    }

    public static var flightCount: Int { flights.count }

    // MARK: Snapshot

    /// The whole picture at `date`: every aircraft with `trailWindow` seconds of history, the sample reports, and a
    /// ground station. Radar comes separately from `radarBlocks(at:)` because it changes slowly.
    public func snapshot(at date: Date, trailWindow: TimeInterval = 15 * 60) -> AviationPicture {
        var picture = AviationPicture(receiver: center)
        let now = date.timeIntervalSinceReferenceDate

        for flight in Self.flights {
            var state = AircraftState(address: flight.address, firstSeen: date.addingTimeInterval(-trailWindow - 600))
            let current = instant(of: flight, at: now)
            state.callsign = flight.callsign
            state.squawk = flight.squawk
            state.altitudeFeet = current.altitudeFeet
            state.coordinate = current.coordinate
            state.groundSpeedKnots = current.groundSpeedKnots
            state.trackDegrees = current.trackDegrees
            state.verticalRateFPM = current.verticalRateFPM
            state.onGround = flight.onGround
            state.emergency = flight.emergency
            state.sources = [.demo]
            state.messageCount = 1_000
            state.lastSeen = date
            state.lastPositionTime = date
            state.signalDBFS = -18 - Double(flight.address % 17)
            if let broadcast = flight.aircraftClass {
                state.aircraftClass = broadcast
            } else {
                let guess = AircraftClass.inferred(callsign: flight.callsign, groundSpeedKnots: current.groundSpeedKnots,
                                                   altitudeFeet: current.altitudeFeet)
                state.aircraftClass = guess
                state.classIsInferred = guess != .unknown
            }

            var moment = now - trailWindow
            while moment <= now {
                let sample = instant(of: flight, at: moment)
                state.history.append(TrackSample(time: Date(timeIntervalSinceReferenceDate: moment), coordinate: sample.coordinate,
                                                 altitudeFeet: sample.altitudeFeet, onGround: flight.onGround))
                moment += 5
            }
            picture.aircraft[flight.address] = state
        }

        picture.stats.messages = Self.flights.count * 1_000
        picture.stats.positions = Self.flights.count * 500
        picture.stats.peakAircraft = Self.flights.count
        picture.stats.farthestNM = 118
        let station = GroundStation(coordinate: GeoMath.destination(from: center, bearingDegrees: 95, distanceNM: 1.0),
                                    slotID: 7, heard: date)
        picture.groundStations[station.id] = station
        for message in messages(at: date) { picture.addMessage(message) }
        for state in picture.aircraft.values.sorted(by: { $0.address < $1.address }) where state.isEmergency {
            // The text is fixed (no position or altitude) so the row keeps its identity from one snapshot to the next.
            let reason = state.squawkAlert?.displayName ?? state.emergency?.label ?? "Emergency"
            picture.addMessage(AviationMessage(
                kind: .aircraftAlert, station: state.callsign, title: "\(state.displayName): \(reason)",
                body: "\(state.displayName) (\(state.addressHex)): \(reason)",
                severity: state.squawkAlert == .radioFailure ? .warning : .critical, origin: "Demo",
                at: date.addingTimeInterval(-90), coordinate: state.coordinate))
        }
        picture.revision += 1
        return picture
    }

    // MARK: Radar

    private struct Cell {
        var bearing: Double          // from the centre, degrees
        var distanceNM: Double
        var radiusNM: Double
        var peakDBZ: Double
        var driftBearing: Double
        var driftKnots: Double
    }

    private static let cells: [Cell] = [
        Cell(bearing: 300, distanceNM: 60, radiusNM: 14, peakDBZ: 58, driftBearing: 110, driftKnots: 22),
        Cell(bearing: 315, distanceNM: 95, radiusNM: 20, peakDBZ: 52, driftBearing: 110, driftKnots: 22),
        Cell(bearing: 280, distanceNM: 82, radiusNM: 11, peakDBZ: 47, driftBearing: 105, driftKnots: 20),
        Cell(bearing: 20, distanceNM: 70, radiusNM: 9, peakDBZ: 44, driftBearing: 120, driftKnots: 15),
        Cell(bearing: 165, distanceNM: 88, radiusNM: 24, peakDBZ: 36, driftBearing: 80, driftKnots: 18),
        Cell(bearing: 200, distanceNM: 55, radiusNM: 8, peakDBZ: 41, driftBearing: 70, driftKnots: 16),
    ]

    /// dBZ-like reflectivity at an offset from the centre (nautical miles east and north).
    private func reflectivity(eastNM: Double, northNM: Double, hours: Double) -> Double {
        var total = 0.0
        for cell in Self.cells {
            let bearing = cell.bearing * Double.pi / 180
            let drift = cell.driftBearing * Double.pi / 180
            let travelled = cell.driftKnots * hours
            let cx = cell.distanceNM * sin(bearing) + travelled * sin(drift)
            let cy = cell.distanceNM * cos(bearing) + travelled * cos(drift)
            let d2 = ((eastNM - cx) * (eastNM - cx) + (northNM - cy) * (northNM - cy)) / (cell.radiusNM * cell.radiusNM)
            if d2 < 9 { total = max(total, cell.peakDBZ * exp(-d2)) }
        }
        return total
    }

    private static func level(forDBZ dbz: Double) -> UInt8 {
        switch dbz {
        case ..<5: return 0
        case ..<20: return 1
        case ..<30: return 2
        case ..<40: return 3
        case ..<45: return 4
        case ..<50: return 5
        case ..<55: return 6
        default: return 7
        }
    }

    /// Radar blocks for a region 8 degrees wide and about 6 tall around the centre, on the same grid FIS-B uses (blocks
    /// 48 by 4 arcminutes, bins 1.5 by 1). Only blocks that hold rain are returned.
    public func radarBlocks(at date: Date) -> [RadarBlock] {
        let hours = (date.timeIntervalSinceReferenceDate / 3_600).truncatingRemainder(dividingBy: 4)
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .gmt, from: date)
        let hour = components.hour ?? 0
        let minute = (components.minute ?? 0) / 5 * 5
        let cosLatitude = max(0.05, cos(center.latitude * Double.pi / 180))

        let northArc = Int(((center.latitude + 3) * 60 / 4).rounded(.down)) * 4
        let southArc = Int(((center.latitude - 3) * 60 / 4).rounded(.down)) * 4
        let westArc = Int(((center.longitude - 4) * 60 / 48).rounded(.down)) * 48
        let eastArc = Int(((center.longitude + 4) * 60 / 48).rounded(.up)) * 48

        var blocks: [RadarBlock] = []
        var blockNorth = northArc
        while blockNorth > southArc {
            var blockWest = westArc
            while blockWest < eastArc {
                var bins = [UInt8](repeating: 0, count: RadarBlock.columns * RadarBlock.rows)
                var any = false
                for row in 0..<RadarBlock.rows {
                    let latitude = (Double(blockNorth) - (Double(row) + 0.5)) / 60
                    let northNM = (latitude - center.latitude) * 60
                    for column in 0..<RadarBlock.columns {
                        let longitude = (Double(blockWest) + (Double(column) + 0.5) * 1.5) / 60
                        let eastNM = (longitude - center.longitude) * 60 * cosLatitude
                        let level = Self.level(forDBZ: reflectivity(eastNM: eastNM, northNM: northNM, hours: hours))
                        bins[row * RadarBlock.columns + column] = level
                        if level >= 2 { any = true }
                    }
                }
                if any {
                    blocks.append(RadarBlock(product: .regional, hours: hour, minutes: minute, scale: 0,
                                             northArcminutes: blockNorth, westArcminutes: blockWest,
                                             heightArcminutes: 4, widthArcminutes: 48, bins: bins))
                }
                blockWest += 48
            }
            blockNorth -= 4
        }
        return blocks
    }

    // MARK: Text

    /// Sample reports for made-up airports (KDMA to KDMD). The times inside the reports are fixed to the last half hour,
    /// so their text (and so their identity in the message list) does not change from one second to the next.
    public func messages(at date: Date) -> [AviationMessage] {
        let calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "UTC") ?? .gmt
        let base = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 1_800).rounded(.down) * 1_800)
        let stamp = { (minutesAgo: Int) -> String in
            let then = base.addingTimeInterval(-Double(minutesAgo) * 60)
            let c = calendar.dateComponents(in: zone, from: then)
            return String(format: "%02d%02d%02dZ", c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
        }
        let texts: [(String, Int)] = [
            ("METAR KDMA \(stamp(3)) 27012G22KT 10SM FEW045 BKN250 24/12 A2992 RMK AO2 SLP132", 3),
            ("SPECI KDMB \(stamp(7)) 18016G26KT 2SM +TSRA BR BKN008CB OVC015 18/17 A2985 RMK AO2 TSB05", 7),
            ("METAR KDMC \(stamp(11)) 00000KT 1/4SM FG VV002 08/08 A3001 RMK AO2", 11),
            ("METAR KDMD \(stamp(14)) VRB03KT 4SM BR SCT020 10/09 A3010 RMK AO2", 14),
            ("METAR KDMA \(stamp(63)) 26010KT 10SM FEW040 BKN240 23/12 A2993 RMK AO2 SLP135", 63),
            ("TAF KDMA \(stamp(20)) 3012/3112 27010KT P6SM SCT050 FM301800 28015G25KT P6SM BKN030 TEMPO 3020/3024 3SM TSRA BKN020CB", 20),
            ("PIREP UUA /OV KDMA090025/TM 1445/FL120/TP C172/TB SEV/RM LLWS ON DEPARTURE", 9),
            ("SIGMET NOVEMBER 3 VALID UNTIL 302100 ISOL SEV TS OBSD AT \(stamp(30)) MOV FROM 27015KT TOPS ABV FL450", 30),
            ("AIRMET SIERRA UPDT 3 FOR IFR AND MTN OBSCN VALID UNTIL 301500 AIRMET IFR CIG BLW 010/VIS BLW 3SM BR", 45),
            ("NOTAM-TFR KDMA TEMPORARY FLIGHT RESTRICTIONS 3NM RADIUS OF KDMA WILDFIRE AERIAL OPERATIONS SFC-3000FT", 60),
            ("WINDS KDMA 6000 2720+05 9000 2735-04 12000 2750-14 18000 2765-30 24000 2785-45", 15),
            ("D-ATIS KDMA INFORMATION BRAVO \(stamp(25)) 27012G22KT 10SM FEW045 BKN250 24/12 A2992 ILS RWY 27 IN USE", 25),
        ]
        return texts.map { text, minutesAgo in
            AviationMessage.fisbReport(text, at: base.addingTimeInterval(-Double(minutesAgo) * 60), origin: "Demo")
        }
    }
}

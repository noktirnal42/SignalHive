import Foundation

// Everything the Passes screen draws is computed here, in plain values, so the views only draw and the geometry,
// time handling and projection are tested.

// MARK: - Timeline

/// Lanes of passes against a time axis. The axis is linear in UTC seconds: local time and daylight-saving changes are
/// the view's labelling job and never bend the layout.
public struct TimelineLayout: Sendable {
    public struct Lane: Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var passes: [RatedPass]
    }

    public let from: Date
    public let through: Date
    /// One lane per satellite, ordered by the satellite's first pass.
    public let lanes: [Lane]
    /// Where the Sun is up at the observer, from its elevation every 5 minutes (empty without an observer).
    public let daylight: [ClosedRange<Date>]

    public init(passes: [RatedPass], from: Date, through: Date, observer: Observer? = nil) {
        self.from = from
        self.through = through
        let grouped = Dictionary(grouping: passes, by: { $0.pass.noradID })
        lanes = grouped.map { id, items in
            let sorted = items.sorted { $0.pass.aos < $1.pass.aos }
            return Lane(id: id, name: sorted[0].record.elements.name, passes: sorted)
        }.sorted { ($0.passes[0].pass.aos, $0.name) < ($1.passes[0].pass.aos, $1.name) }
        daylight = observer.map { Self.daylight(for: $0, from: from, through: through) } ?? []
    }

    public func x(for date: Date, width: Double) -> Double {
        let span = through.timeIntervalSince(from)
        guard span > 0 else { return 0 }
        return date.timeIntervalSince(from) / span * width
    }

    private static func daylight(for observer: Observer, from: Date, through: Date) -> [ClosedRange<Date>] {
        guard through > from else { return [] }
        var ranges: [ClosedRange<Date>] = []
        var start: Date?
        var last = from
        var moment = from
        while moment <= through {
            if SunPosition.elevationDegrees(from: observer, at: moment) > 0 {
                if start == nil { start = moment }
                last = moment
            } else if let begun = start {
                ranges.append(begun...last)
                start = nil
            }
            if moment == through { break }
            moment = min(through, moment.addingTimeInterval(300))
        }
        if let begun = start { ranges.append(begun...last) }
        return ranges
    }
}

// MARK: - Sky plot

public enum PolarProjection {
    /// Zenith at the centre, the horizon on the ring of `radius`, north up (+y) and east to the right (+x). Below the
    /// horizon is drawn on the horizon ring.
    public static func point(azimuthDegrees: Double, elevationDegrees: Double, radius: Double) -> (x: Double, y: Double) {
        let elevation = max(0, min(90, elevationDegrees))
        let r = radius * (90 - elevation) / 90
        let azimuth = azimuthDegrees * .pi / 180
        return (r * sin(azimuth), r * cos(azimuth))
    }
}

// MARK: - Ground track

public enum GroundTrack {
    /// Splits a track where the longitude jumps by more than 180 degrees (the antimeridian), so a map polyline does not
    /// draw a line across the whole world.
    public static func segments(_ points: [GeoCoordinate]) -> [[GeoCoordinate]] {
        guard var current = points.first.map({ [$0] }) else { return [] }
        var result: [[GeoCoordinate]] = []
        for (previous, next) in zip(points, points.dropFirst()) {
            if abs(next.longitude - previous.longitude) > 180 {
                result.append(current)
                current = []
            }
            current.append(next)
        }
        result.append(current)
        return result
    }

    /// The point on the ground under the satellite, and its height above the ellipsoid.
    public static func subpoint(of state: StateVector, at date: Date) -> (coordinate: GeoCoordinate, altitudeKM: Double) {
        let gmst = TimeScales.gmstRadians(date)
        let c = cos(gmst), s = sin(gmst)
        let p = state.position
        let ecef = Vector3(c * p.x + s * p.y, -s * p.x + c * p.y, p.z)
        let geodetic = Geodesy.geodetic(fromECEF: ecef)
        return (GeoCoordinate(latitude: geodetic.latitudeDegrees, longitude: geodetic.longitudeDegrees), geodetic.altitudeKM)
    }

    /// Sub-satellite points between two times, one every `step` seconds; empty where the orbit model fails.
    public static func points(elements: OrbitalElements, from: Date, through: Date, step: TimeInterval = 20) -> [GeoCoordinate] {
        guard let propagator = try? SGP4Propagator(elements), through > from, step > 0 else { return [] }
        var result: [GeoCoordinate] = []
        var moment = from
        while moment <= through {
            guard let state = try? propagator.state(at: moment) else { break }
            result.append(subpoint(of: state, at: moment).coordinate)
            moment.addTimeInterval(step)
        }
        return result
    }

    /// How far along the ground the satellite can be seen to the horizon: Re * acos(Re / (Re + h)).
    public static func footprintRadiusKM(altitudeKM: Double) -> Double {
        let re = WGS84.equatorialRadiusKM
        return re * acos(re / (re + max(0, altitudeKM)))
    }
}

// MARK: - Hand pointing

/// Where to point at any moment of a pass, for a person with a hand-held antenna (or, later, a rotator): interpolated
/// from the 5-second track.
public struct PointingGuide: Sendable {
    public enum Phase: Sendable, Equatable {
        case beforeAOS(seconds: Double)
        case inPass(secondsToLOS: Double)
        case after
    }

    public struct State: Sendable {
        public var phase: Phase
        /// Before AOS this is where the satellite will appear; after LOS there is none.
        public var azimuthDegrees: Double?
        public var elevationDegrees: Double?
        public var compass: String
        var rangeRateKMPerSec: Double?

        /// First-order Doppler shift of a carrier right now, or nil outside the pass.
        public func dopplerHz(carrierHz: Double) -> Double? {
            rangeRateKMPerSec.map { Topocentric.dopplerShiftHz(carrierHz: carrierHz, rangeRateKMPerSec: $0) }
        }
    }

    private let pass: PredictedPass

    public init(pass: PredictedPass) {
        self.pass = pass
    }

    public func state(at date: Date) -> State {
        if date < pass.aos {
            let azimuth = pass.track.first?.azimuthDegrees ?? pass.aosAzimuthDegrees
            return State(phase: .beforeAOS(seconds: pass.aos.timeIntervalSince(date)), azimuthDegrees: azimuth,
                         elevationDegrees: nil, compass: Self.compass(forAzimuth: azimuth), rangeRateKMPerSec: nil)
        }
        guard date <= pass.los, let point = interpolated(at: date) else {
            return State(phase: .after, azimuthDegrees: nil, elevationDegrees: nil, compass: "", rangeRateKMPerSec: nil)
        }
        return State(phase: .inPass(secondsToLOS: pass.los.timeIntervalSince(date)), azimuthDegrees: point.azimuthDegrees,
                     elevationDegrees: point.elevationDegrees, compass: Self.compass(forAzimuth: point.azimuthDegrees),
                     rangeRateKMPerSec: point.rangeRateKMPerSec)
    }

    private func interpolated(at date: Date) -> PassPoint? {
        let track = pass.track
        guard let first = track.first, let last = track.last else { return nil }
        if date <= first.time { return first }
        if date >= last.time { return last }
        var low = 0, high = track.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if track[mid].time <= date { low = mid } else { high = mid }
        }
        let a = track[low], b = track[high]
        let span = b.time.timeIntervalSince(a.time)
        let t = span > 0 ? date.timeIntervalSince(a.time) / span : 0
        // Azimuth goes the short way round, so 350 to 0 passes through 355 and not 175.
        var delta = (b.azimuthDegrees - a.azimuthDegrees).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        var azimuth = (a.azimuthDegrees + delta * t).truncatingRemainder(dividingBy: 360)
        if azimuth < 0 { azimuth += 360 }
        return PassPoint(time: date, azimuthDegrees: azimuth,
                         elevationDegrees: a.elevationDegrees + (b.elevationDegrees - a.elevationDegrees) * t,
                         rangeKM: a.rangeKM + (b.rangeKM - a.rangeKM) * t,
                         rangeRateKMPerSec: a.rangeRateKMPerSec + (b.rangeRateKMPerSec - a.rangeRateKMPerSec) * t)
    }

    /// The 16-point compass name of an azimuth ("N", "NNE", "NE", ...).
    public static func compass(forAzimuth azimuth: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        var normalized = azimuth.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        return names[Int((normalized / 22.5).rounded()) % 16]
    }
}

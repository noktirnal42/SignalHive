import Foundation

/// One remembered position of an aircraft.
public struct TrackSample: Sendable, Hashable, Codable {
    public var time: Date
    public var coordinate: GeoCoordinate
    public var altitudeFeet: Int?
    public var onGround: Bool

    public init(time: Date, coordinate: GeoCoordinate, altitudeFeet: Int?, onGround: Bool = false) {
        self.time = time
        self.coordinate = coordinate
        self.altitudeFeet = altitudeFeet
        self.onGround = onGround
    }
}

/// The recent positions of one aircraft, kept thin enough to hold hundreds of aircraft for half an hour.
///
/// Position reports arrive about twice a second per aircraft; drawing every one would be wasted work, so a sample is
/// kept only when the aircraft has moved, climbed or descended noticeably, or when enough time has passed.
public struct TrackHistory: Sendable, Equatable {
    public private(set) var samples: [TrackSample] = []

    /// Samples older than this are dropped by `trim(now:)`.
    public var maximumAge: TimeInterval = 30 * 60
    public var maximumSamples = 900
    /// Never keep two samples closer in time than this.
    public var minimumSpacing: TimeInterval = 2
    /// Keep a sample when the aircraft moved this far ...
    public var minimumDistanceNM = 0.03
    /// ... or changed altitude this much ...
    public var minimumAltitudeChangeFeet = 100
    /// ... or when this long has passed.
    public var heartbeat: TimeInterval = 20

    public init() {}

    /// Adds a sample if it adds information. Returns whether it was kept.
    @discardableResult
    public mutating func append(_ sample: TrackSample) -> Bool {
        guard sample.coordinate.isValid else { return false }
        guard let last = samples.last else {
            samples.append(sample)
            return true
        }
        let elapsed = sample.time.timeIntervalSince(last.time)
        guard elapsed >= minimumSpacing else { return false }
        let moved = GeoMath.distanceNM(last.coordinate, sample.coordinate)
        var changedAltitude = false
        if let a = last.altitudeFeet, let b = sample.altitudeFeet {
            changedAltitude = abs(b - a) >= minimumAltitudeChangeFeet
        } else if (last.altitudeFeet == nil) != (sample.altitudeFeet == nil) {
            changedAltitude = true
        }
        guard moved >= minimumDistanceNM || changedAltitude || elapsed >= heartbeat else { return false }
        samples.append(sample)
        if samples.count > maximumSamples { samples.removeFirst(samples.count - maximumSamples) }
        return true
    }

    /// Drops samples older than `maximumAge`.
    public mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-maximumAge)
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }) {
            if firstKept > 0 { samples.removeFirst(firstKept) }
        } else {
            samples.removeAll()
        }
    }

    public func samples(since date: Date) -> [TrackSample] {
        samples.filter { $0.time >= date }
    }

    /// Lowest and highest altitude remembered, when any is known.
    public var altitudeRange: ClosedRange<Int>? {
        let altitudes = samples.compactMap(\.altitudeFeet)
        guard let low = altitudes.min(), let high = altitudes.max() else { return nil }
        return low...high
    }

    /// Distance flown along the remembered track, nautical miles.
    public var lengthNM: Double {
        guard samples.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<samples.count {
            total += GeoMath.distanceNM(samples[index - 1].coordinate, samples[index].coordinate)
        }
        return total
    }
}

/// A short straight piece of trail with one color.
public struct TrailSegment: Sendable, Equatable {
    public var from: GeoCoordinate
    public var to: GeoCoordinate
    /// The altitude color at the middle of the piece.
    public var color: RGB8
    /// 0 for the newest piece, 1 for the oldest one inside the window.
    public var age: Double
    /// Opacity: 1 for the newest, fading to 0.25 at the oldest.
    public var alpha: Double
}

public enum TrailBuilder {
    /// Turns remembered positions into colored pieces that show where an aircraft has been and how high it was.
    ///
    /// A climb or descent between two samples is split into pieces of about `feetPerPiece`, each colored for its own
    /// altitude, so a trail fades smoothly from one color to the next without needing gradient strokes.
    ///
    /// - Parameters:
    ///   - window: How far back to draw.
    ///   - maximumGap: Two samples further apart in time than this are not joined (the signal was lost).
    ///   - maximumSpeedKnots: Two samples that would imply a faster aircraft are not joined (a bad position).
    public static func segments(
        from samples: [TrackSample],
        now: Date,
        window: TimeInterval,
        maximumGap: TimeInterval = 60,
        maximumSpeedKnots: Double = 1_500,
        feetPerPiece: Int = 600,
        maximumPieces: Int = 8
    ) -> [TrailSegment] {
        guard samples.count > 1, window > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-window)
        var result: [TrailSegment] = []
        result.reserveCapacity(samples.count)

        for index in 1..<samples.count {
            let a = samples[index - 1]
            let b = samples[index]
            guard b.time >= cutoff else { continue }
            let elapsed = b.time.timeIntervalSince(a.time)
            guard elapsed > 0, elapsed <= maximumGap else { continue }
            let distance = GeoMath.distanceNM(a.coordinate, b.coordinate)
            guard distance / (elapsed / 3600) <= maximumSpeedKnots else { continue }

            var pieces = 1
            if let altA = a.altitudeFeet, let altB = b.altitudeFeet, feetPerPiece > 0 {
                pieces = max(1, min(maximumPieces, Int((Double(abs(altB - altA)) / Double(feetPerPiece)).rounded(.up))))
            }
            for piece in 0..<pieces {
                let t0 = Double(piece) / Double(pieces)
                let t1 = Double(piece + 1) / Double(pieces)
                let mid = (t0 + t1) / 2
                let middleTime = a.time.addingTimeInterval(elapsed * mid)
                let age = max(0, min(1, now.timeIntervalSince(middleTime) / window))
                result.append(TrailSegment(
                    from: interpolate(a.coordinate, b.coordinate, t0),
                    to: interpolate(a.coordinate, b.coordinate, t1),
                    color: color(a, b, at: mid),
                    age: age,
                    alpha: 1 - 0.75 * age
                ))
            }
        }
        return result
    }

    private static func interpolate(_ a: GeoCoordinate, _ b: GeoCoordinate, _ t: Double) -> GeoCoordinate {
        // Take the short way round when the pair straddles the antimeridian.
        var deltaLongitude = b.longitude - a.longitude
        if deltaLongitude > 180 { deltaLongitude -= 360 }
        if deltaLongitude < -180 { deltaLongitude += 360 }
        return GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                             longitude: GeoMath.normalizedLongitude(a.longitude + deltaLongitude * t))
    }

    private static func color(_ a: TrackSample, _ b: TrackSample, at t: Double) -> RGB8 {
        if a.onGround && b.onGround { return AltitudeColorScale.onGroundColor }
        switch (a.altitudeFeet, b.altitudeFeet) {
        case let (x?, y?):
            return AltitudeColorScale.color(forFeet: Double(x) + Double(y - x) * t)
        case let (x?, nil):
            return AltitudeColorScale.color(forFeet: Double(x))
        case let (nil, y?):
            return AltitudeColorScale.color(forFeet: Double(y))
        case (nil, nil):
            return AltitudeColorScale.unknownColor
        }
    }
}

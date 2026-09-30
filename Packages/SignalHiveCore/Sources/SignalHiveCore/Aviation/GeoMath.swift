import Foundation

/// A point on the globe, in degrees. The aviation model uses its own type so it does not depend on CoreLocation
/// (and so it is `Hashable` and `Codable` without ceremony).
public struct GeoCoordinate: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Finite and on the globe. Decoders can hand over garbage when a frame is corrupt but still passes a checksum.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

public enum GeoMath {
    public static let earthRadiusNM = 3440.065

    /// The latitude at which the Web Mercator projection used by map tiles stops (about 85.05 degrees).
    public static let maximumMercatorLatitude = 85.0511287798

    /// Great-circle distance in nautical miles.
    public static func distanceNM(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let toRadians = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * toRadians
        let dLon = (b.longitude - a.longitude) * toRadians
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * toRadians) * cos(b.latitude * toRadians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusNM * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// Initial true bearing from `a` to `b`, 0 ..< 360 degrees.
    public static func bearingDegrees(from a: GeoCoordinate, to b: GeoCoordinate) -> Double {
        let toRadians = Double.pi / 180
        let lat1 = a.latitude * toRadians
        let lat2 = b.latitude * toRadians
        let dLon = (b.longitude - a.longitude) * toRadians
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The point reached from `start` after `distanceNM` on a constant initial bearing along a great circle.
    public static func destination(from start: GeoCoordinate, bearingDegrees: Double, distanceNM: Double) -> GeoCoordinate {
        let toRadians = Double.pi / 180
        let angular = distanceNM / earthRadiusNM
        let bearing = bearingDegrees * toRadians
        let lat1 = start.latitude * toRadians
        let lon1 = start.longitude * toRadians
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
        return GeoCoordinate(latitude: lat2 / toRadians, longitude: normalizedLongitude(lon2 / toRadians))
    }

    /// Wraps a longitude into -180 ... 180.
    public static func normalizedLongitude(_ longitude: Double) -> Double {
        guard longitude.isFinite else { return longitude }
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    /// Web Mercator "y" for a latitude (radians of the unit sphere), clamped at the projection's limit.
    public static func mercatorY(latitude: Double) -> Double {
        let clamped = max(-maximumMercatorLatitude, min(maximumMercatorLatitude, latitude))
        return log(tan(Double.pi / 4 + clamped * Double.pi / 360))
    }

    /// The inverse of `mercatorY(latitude:)`, in degrees.
    public static func latitude(mercatorY y: Double) -> Double {
        (2 * atan(exp(y)) - Double.pi / 2) * 180 / .pi
    }
}

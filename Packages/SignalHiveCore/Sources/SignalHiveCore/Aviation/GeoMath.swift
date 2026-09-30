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

    /// Reads a position typed by a person: "40.1234, -100.5", "40.1234 -100.5", or "40.1234 N 100.5 W" (degree signs
    /// and letters are optional; S and W make a value negative). Returns nil when it is not a valid position.
    public static func parse(_ text: String) -> GeoCoordinate? {
        let cleaned = text.uppercased()
            .replacingOccurrences(of: "\u{00B0}", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ";", with: " ")
        var numbers: [Double] = []
        var hemispheres: [Character?] = []
        for token in cleaned.split(whereSeparator: { $0.isWhitespace }) {
            var body = String(token)
            var hemisphere: Character?
            if let last = body.last, "NSEW".contains(last) {
                hemisphere = last
                body.removeLast()
            } else if let first = body.first, "NSEW".contains(first) {
                hemisphere = first
                body.removeFirst()
            }
            if body.isEmpty {
                // A letter on its own belongs to the number before it: "40.1 N".
                if let hemisphere, !numbers.isEmpty, hemispheres[hemispheres.count - 1] == nil {
                    hemispheres[hemispheres.count - 1] = hemisphere
                    continue
                }
                return nil
            }
            guard let value = Double(body), value.isFinite else { return nil }
            numbers.append(value)
            hemispheres.append(hemisphere)
        }
        guard numbers.count == 2 else { return nil }
        var latitude = numbers[0]
        var longitude = numbers[1]
        if hemispheres[0] == "S" { latitude = -abs(latitude) }
        if hemispheres[1] == "W" { longitude = -abs(longitude) }
        // "100.5 W 40.1 N": longitude first, when the letters say so.
        if hemispheres[0] == "E" || hemispheres[0] == "W" || hemispheres[1] == "N" || hemispheres[1] == "S" {
            swap(&latitude, &longitude)
            if hemispheres[1] == "S" { latitude = -abs(latitude) }
            if hemispheres[0] == "W" { longitude = -abs(longitude) }
        }
        let result = GeoCoordinate(latitude: latitude, longitude: longitude)
        return result.isValid ? result : nil
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

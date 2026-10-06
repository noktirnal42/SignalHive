import Foundation

public enum WGS84 {
    public static let equatorialRadiusKM = 6378.137
    public static let flattening = 1 / 298.257223563
    /// Earth's rotation rate in radians per second.
    public static let earthRotationRadPerSec = 7.292115146706979e-5

    static let eccentricitySquared = flattening * (2 - flattening)
}

/// Where the receiver is. Altitude is metres above the WGS-84 ellipsoid (close enough to sea level for a pass table).
public struct Observer: Sendable, Equatable {
    public var latitudeDegrees: Double
    public var longitudeDegrees: Double
    public var altitudeMeters: Double

    public init(latitudeDegrees: Double, longitudeDegrees: Double, altitudeMeters: Double = 0) {
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
        self.altitudeMeters = altitudeMeters
    }

    public init(_ coordinate: GeoCoordinate, altitudeMeters: Double = 0) {
        self.init(latitudeDegrees: coordinate.latitude, longitudeDegrees: coordinate.longitude,
                  altitudeMeters: altitudeMeters)
    }

    public var isValid: Bool {
        latitudeDegrees.isFinite && longitudeDegrees.isFinite && altitudeMeters.isFinite
            && (-90...90).contains(latitudeDegrees) && (-180...180).contains(longitudeDegrees)
    }
}

public enum Geodesy {
    /// The observer's position in Earth-fixed kilometres.
    public static func ecef(of observer: Observer) -> Vector3 {
        let lat = observer.latitudeDegrees * .pi / 180
        let lon = observer.longitudeDegrees * .pi / 180
        let height = observer.altitudeMeters / 1000
        let e2 = WGS84.eccentricitySquared
        let sinLat = sin(lat)
        let n = WGS84.equatorialRadiusKM / (1 - e2 * sinLat * sinLat).squareRoot()
        return Vector3((n + height) * cos(lat) * cos(lon),
                       (n + height) * cos(lat) * sin(lon),
                       (n * (1 - e2) + height) * sinLat)
    }

    /// Geodetic latitude, longitude and height of an Earth-fixed position, by fixed-point iteration on the latitude
    /// (it gains about two digits a pass, so ten passes are far more than the 1e-12 needed, poles included).
    public static func geodetic(fromECEF p: Vector3) -> (latitudeDegrees: Double, longitudeDegrees: Double, altitudeKM: Double) {
        let a = WGS84.equatorialRadiusKM
        let e2 = WGS84.eccentricitySquared
        let longitude = atan2(p.y, p.x)
        let rho = hypot(p.x, p.y)
        var latitude = atan2(p.z, rho * (1 - e2))
        for _ in 0..<12 {
            let sinLat = sin(latitude)
            let n = a / (1 - e2 * sinLat * sinLat).squareRoot()
            let next = atan2(p.z + e2 * n * sinLat, rho)
            let done = abs(next - latitude) < 1e-15
            latitude = next
            if done { break }
        }
        let sinLat = sin(latitude), cosLat = cos(latitude)
        let n = a / (1 - e2 * sinLat * sinLat).squareRoot()
        // rho / cos(lat) loses all precision at the poles, z / sin(lat) loses it at the equator: use whichever is well conditioned.
        let height = abs(cosLat) > abs(sinLat) ? rho / cosLat - n : p.z / sinLat - n * (1 - e2)
        return (latitude * 180 / .pi, longitude * 180 / .pi, height)
    }
}

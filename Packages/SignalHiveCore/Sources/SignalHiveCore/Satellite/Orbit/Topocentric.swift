import Foundation

/// Where a satellite is in an observer's sky at one instant.
public struct LookAngle: Sendable, Equatable {
    public var time: Date
    /// Degrees clockwise from true north, 0 up to (not including) 360.
    public var azimuthDegrees: Double
    public var elevationDegrees: Double
    public var rangeKM: Double
    /// Positive when the satellite is receding.
    public var rangeRateKMPerSec: Double

    public init(time: Date, azimuthDegrees: Double, elevationDegrees: Double, rangeKM: Double, rangeRateKMPerSec: Double) {
        self.time = time
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.rangeKM = rangeKM
        self.rangeRateKMPerSec = rangeRateKMPerSec
    }
}

/// Look angles and Doppler for a TEME state seen from a ground observer.
///
/// Ignored on purpose, each worth well under the pass-table resolution: light travel time (about 4 ms for a 1200 km
/// slant range, 30 m of satellite motion), polar motion (under 0.5 arcsecond), and UT1 minus UTC (under 0.9 s, which
/// is under 0.4 km of along-track position; UTC stands in for UT1).
public enum Topocentric {
    public static let speedOfLightKMPerSec = 299_792.458

    public static func look(_ state: StateVector, at date: Date, from observer: Observer) -> LookAngle {
        // TEME to Earth-fixed is a rotation about the pole by the sidereal angle.
        let gmst = TimeScales.gmstRadians(date)
        let c = cos(gmst), s = sin(gmst)
        let p = state.position, velocity = state.velocity
        let position = Vector3(c * p.x + s * p.y, -s * p.x + c * p.y, p.z)
        // Velocity relative to the turning Earth: rotate it, then take away omega x r.
        let w = WGS84.earthRotationRadPerSec
        let relativeVelocity = Vector3(c * velocity.x + s * velocity.y + w * position.y,
                                       -s * velocity.x + c * velocity.y - w * position.x,
                                       velocity.z)

        let rho = position - Geodesy.ecef(of: observer)
        let lat = observer.latitudeDegrees * .pi / 180
        let lon = observer.longitudeDegrees * .pi / 180
        let east = -sin(lon) * rho.x + cos(lon) * rho.y
        let north = -sin(lat) * cos(lon) * rho.x - sin(lat) * sin(lon) * rho.y + cos(lat) * rho.z
        let up = cos(lat) * cos(lon) * rho.x + cos(lat) * sin(lon) * rho.y + sin(lat) * rho.z

        let range = rho.length
        let elevation = range > 0 ? asin(max(-1, min(1, up / range))) * 180 / .pi : 90
        var azimuth = atan2(east, north) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        if azimuth >= 360 { azimuth -= 360 }
        let rangeRate = range > 0 ? rho.dot(relativeVelocity) / range : 0
        return LookAngle(time: date, azimuthDegrees: azimuth, elevationDegrees: elevation, rangeKM: range,
                         rangeRateKMPerSec: rangeRate)
    }

    /// First-order Doppler shift: f * (-range-rate / c). Receding (positive range-rate) lowers the frequency.
    public static func dopplerShiftHz(carrierHz: Double, rangeRateKMPerSec: Double) -> Double {
        carrierHz * (-rangeRateKMPerSec / speedOfLightKMPerSec)
    }

    public static func receivedFrequencyHz(carrierHz: Double, rangeRateKMPerSec: Double) -> Double {
        carrierHz + dopplerShiftHz(carrierHz: carrierHz, rangeRateKMPerSec: rangeRateKMPerSec)
    }
}

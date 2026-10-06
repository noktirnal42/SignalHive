import Foundation

/// The Sun for pass tables: is it day where the observer is, is the satellite lit. Low-precision solar coordinates
/// (Meeus, Astronomical Algorithms, chapter 25), good to about 0.01 degrees, which is far finer than a daylight band
/// on a timeline or a yes/no eclipse test needs. TT is taken as UTC (about 69 s, 0.001 degrees of solar motion).
public enum SunPosition {
    static let astronomicalUnitKM = 149_597_870.7

    /// Geocentric position of the Sun in kilometres, in the equatorial frame of date (apparent place).
    public static func vector(at date: Date) -> Vector3 {
        let t = (TimeScales.julianDate(date) - 2_451_545.0) / 36_525
        let radians = Double.pi / 180
        let meanLongitude = 280.46646 + 36_000.76983 * t + 0.0003032 * t * t
        let meanAnomaly = (357.52911 + 35_999.05029 * t - 0.0001537 * t * t) * radians
        let eccentricity = 0.016708634 - 0.000042037 * t - 0.0000001267 * t * t
        let equationOfCentre = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(meanAnomaly)
            + (0.019993 - 0.000101 * t) * sin(2 * meanAnomaly)
            + 0.000289 * sin(3 * meanAnomaly)
        let trueLongitude = meanLongitude + equationOfCentre
        let trueAnomaly = meanAnomaly + equationOfCentre * radians
        let distanceAU = 1.000001018 * (1 - eccentricity * eccentricity) / (1 + eccentricity * cos(trueAnomaly))

        // Apparent longitude: nutation and aberration, from the longitude of the Moon's node.
        let node = (125.04 - 1934.136 * t) * radians
        let apparentLongitude = (trueLongitude - 0.00569 - 0.00478 * sin(node)) * radians
        let obliquity = (23.439291 - 0.0130042 * t + 0.00256 * cos(node)) * radians

        let distanceKM = distanceAU * astronomicalUnitKM
        return Vector3(distanceKM * cos(apparentLongitude),
                       distanceKM * cos(obliquity) * sin(apparentLongitude),
                       distanceKM * sin(obliquity) * sin(apparentLongitude))
    }

    /// Geometric elevation of the Sun's centre above the observer's horizon (no refraction).
    public static func elevationDegrees(from observer: Observer, at date: Date) -> Double {
        let sun = vector(at: date)
        let rightAscension = atan2(sun.y, sun.x)
        let declination = asin(sun.z / sun.length)
        // Geocentric latitude, so the ellipsoid's flattening does not tilt the horizon by up to 0.19 degrees.
        let geodetic = observer.latitudeDegrees * .pi / 180
        let latitude = atan((1 - WGS84.eccentricitySquared) * tan(geodetic))
        let hourAngle = TimeScales.gmstRadians(date) + observer.longitudeDegrees * .pi / 180 - rightAscension
        let sine = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)
        return asin(max(-1, min(1, sine))) * 180 / .pi
    }

    /// Cylindrical Earth shadow: a satellite is dark when it is on the night side and inside the cylinder of the
    /// Earth's radius along the Sun line. The penumbra (a few seconds of dimming) is ignored.
    public static func isSunlit(satellite: Vector3, sun: Vector3) -> Bool {
        let direction = sun * (1 / sun.length)
        let along = satellite.dot(direction)
        if along > 0 { return true }
        return (satellite - direction * along).length > WGS84.equatorialRadiusKM
    }
}

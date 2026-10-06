import Foundation

/// Time conversions for orbit work. UTC is treated as UT1: the difference stays under 0.9 s, which moves a satellite's
/// ground position by under 0.4 km and is ignored (the pass predictor documents it).
public enum TimeScales {
    /// Unix time of J2000.0 (2000-01-01 12:00 UTC).
    private static let j2000UnixSeconds = 946_728_000.0

    public static func julianDate(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// Greenwich mean sidereal time by the IAU-1982 expression, in [0, 2π). Days since J2000 are taken from the Unix
    /// time directly: a Julian date near 2.46 million has only about 20 µs of resolution as a double, which is already
    /// 1.5e-9 rad of Earth rotation.
    public static func gmstRadians(_ date: Date) -> Double {
        let days = (date.timeIntervalSince1970 - j2000UnixSeconds) / 86_400
        let centuries = days / 36_525
        var degrees = 280.46061837 + 360.98564736629 * days
            + 0.000387933 * centuries * centuries - centuries * centuries * centuries / 38_710_000
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        let radians = degrees * .pi / 180
        return radians < 2 * .pi ? radians : 0
    }
}

import Foundation

/// Text for the numbers pilots and controllers read: flight levels, feet per minute, knots.
public enum AviationFormat {
    private static let placeholder = "\u{2014}"

    /// Flight level at and above 18,000 ft (the US transition altitude), feet below, "GND" on the ground.
    public static func altitude(_ feet: Int?, onGround: Bool = false) -> String {
        if onGround { return "GND" }
        guard let feet else { return placeholder }
        if feet >= 18_000 { return String(format: "FL%03d", feet / 100) }
        return grouped(feet) + " ft"
    }

    /// Short form for map labels: "FL350" or "3,200".
    public static func altitudeLabel(_ feet: Int?, onGround: Bool = false) -> String {
        if onGround { return "GND" }
        guard let feet else { return placeholder }
        if feet >= 18_000 { return String(format: "FL%03d", feet / 100) }
        return grouped(feet)
    }

    public static func speed(_ knots: Double?) -> String {
        guard let knots, knots.isFinite else { return placeholder }
        return "\(Int(knots.rounded())) kt"
    }

    public static func track(_ degrees: Double?) -> String {
        guard let degrees, degrees.isFinite else { return placeholder }
        return String(format: "%03d\u{00B0}", Int(degrees.rounded()) % 360)
    }

    public static func verticalRate(_ feetPerMinute: Int?) -> String {
        guard let feetPerMinute else { return placeholder }
        if abs(feetPerMinute) < 100 { return "level" }
        return (feetPerMinute > 0 ? "+" : "-") + grouped(abs(feetPerMinute)) + " fpm"
    }

    public static func distance(_ nauticalMiles: Double?) -> String {
        guard let nauticalMiles, nauticalMiles.isFinite else { return placeholder }
        return nauticalMiles < 100 ? String(format: "%.1f NM", nauticalMiles) : "\(Int(nauticalMiles.rounded())) NM"
    }

    /// "3 s", "2 min", "1 h 5 min".
    public static func age(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        if total < 3_600 { return "\(total / 60) min" }
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(total / 3_600) h" : "\(total / 3_600) h \(minutes) min"
    }

    public static func coordinate(_ coordinate: GeoCoordinate) -> String {
        String(format: "%.4f\u{00B0}%@ %.4f\u{00B0}%@", abs(coordinate.latitude), coordinate.latitude >= 0 ? "N" : "S",
               abs(coordinate.longitude), coordinate.longitude >= 0 ? "E" : "W")
    }

    /// 12345 becomes "12,345".
    public static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }
}

import Foundation

/// An 8-bit sRGB color without any UI framework, so colors can be computed and tested in the core package.
public struct RGB8: Sendable, Hashable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Linear mix in sRGB space: `fraction` 0 is this color, 1 is `other`.
    public func mixed(with other: RGB8, fraction: Double) -> RGB8 {
        let t = max(0, min(1, fraction))
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded())
        }
        return RGB8(mix(red, other.red), mix(green, other.green), mix(blue, other.blue))
    }

    /// Scales toward black (`factor` < 1) or toward white (`factor` > 1, up to 2), the same tone rule the icon
    /// preview in `script/generate_aircraft_icons.py` uses.
    public func toned(_ factor: Double) -> RGB8 {
        if factor <= 1 {
            let f = max(0, factor)
            return RGB8(UInt8((Double(red) * f).rounded()), UInt8((Double(green) * f).rounded()), UInt8((Double(blue) * f).rounded()))
        }
        return mixed(with: RGB8(255, 255, 255), fraction: min(1, factor - 1))
    }

    /// Components in 0 ... 1.
    public var unit: (red: Double, green: Double, blue: Double) {
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }
}

/// Maps altitude to the color of an aircraft and its trail: warm near the ground, through green and cyan, to violet
/// and magenta at the flight levels airliners use.
///
/// The ramp is tuned for a dark map, and `script/generate_aircraft_icons.py` repeats the stops so the icon preview
/// sheet shows the same colors.
public enum AltitudeColorScale {
    public struct Stop: Sendable, Equatable {
        public var feet: Int
        public var color: RGB8
    }

    public static let stops: [Stop] = [
        Stop(feet: 0, color: RGB8(255, 90, 60)),
        Stop(feet: 1_000, color: RGB8(255, 130, 40)),
        Stop(feet: 3_000, color: RGB8(255, 190, 40)),
        Stop(feet: 6_000, color: RGB8(230, 235, 60)),
        Stop(feet: 10_000, color: RGB8(90, 225, 90)),
        Stop(feet: 15_000, color: RGB8(40, 220, 190)),
        Stop(feet: 20_000, color: RGB8(40, 175, 245)),
        Stop(feet: 30_000, color: RGB8(90, 120, 255)),
        Stop(feet: 40_000, color: RGB8(170, 100, 255)),
        Stop(feet: 45_000, color: RGB8(240, 100, 230)),
    ]

    /// Aircraft (and ground vehicles) on the surface.
    public static let onGroundColor = RGB8(150, 160, 170)
    /// Altitude not received yet.
    public static let unknownColor = RGB8(120, 132, 150)

    public static let maximumFeet = 45_000

    /// Altitudes labelled on a legend.
    public static let legendTicks: [Int] = [0, 5_000, 10_000, 20_000, 30_000, 40_000]

    public static func color(altitudeFeet: Int?, onGround: Bool = false) -> RGB8 {
        if onGround { return onGroundColor }
        guard let altitudeFeet else { return unknownColor }
        return color(forFeet: Double(altitudeFeet))
    }

    /// The ramp color at an altitude: below the first stop and above the last it stays at the end colors.
    public static func color(forFeet feet: Double) -> RGB8 {
        guard let first = stops.first, let last = stops.last else { return unknownColor }
        if feet <= Double(first.feet) { return first.color }
        if feet >= Double(last.feet) { return last.color }
        for index in 1..<stops.count {
            let upper = stops[index]
            if feet <= Double(upper.feet) {
                let lower = stops[index - 1]
                let span = Double(upper.feet - lower.feet)
                return lower.color.mixed(with: upper.color, fraction: (feet - Double(lower.feet)) / span)
            }
        }
        return last.color
    }

    /// Position of an altitude along a legend bar (0 ... 1).
    public static func legendFraction(feet: Int) -> Double {
        max(0, min(1, Double(feet) / Double(maximumFeet)))
    }
}

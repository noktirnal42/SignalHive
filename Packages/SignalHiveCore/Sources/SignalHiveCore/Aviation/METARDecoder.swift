import Foundation

/// The FAA's flight categories, from the lower of ceiling and visibility.
public enum FlightCategory: String, Sendable, Codable, CaseIterable, Comparable {
    case vfr = "VFR"
    case mvfr = "MVFR"
    case ifr = "IFR"
    case lifr = "LIFR"
    case unknown = "N/A"

    public var displayName: String {
        switch self {
        case .vfr: return "VFR (visual)"
        case .mvfr: return "MVFR (marginal)"
        case .ifr: return "IFR (instrument)"
        case .lifr: return "LIFR (low instrument)"
        case .unknown: return "Unknown"
        }
    }

    /// Worse conditions rank higher.
    private var rank: Int {
        switch self {
        case .unknown: return -1
        case .vfr: return 0
        case .mvfr: return 1
        case .ifr: return 2
        case .lifr: return 3
        }
    }

    public static func < (lhs: FlightCategory, rhs: FlightCategory) -> Bool { lhs.rank < rhs.rank }

    /// Ceiling is the lowest broken or overcast layer (or vertical visibility). VFR: ceiling above 3,000 ft and
    /// visibility over 5 miles. MVFR: 1,000 to 3,000 ft or 3 to 5 miles. IFR: 500 to below 1,000 ft or 1 to below 3
    /// miles. LIFR: below 500 ft or below 1 mile. A report with neither is unknown.
    public static func from(visibilityMiles: Double?, ceilingFeet: Int?) -> FlightCategory {
        guard visibilityMiles != nil || ceilingFeet != nil else { return .unknown }
        var result = FlightCategory.vfr
        if let visibility = visibilityMiles {
            if visibility < 1 {
                result = max(result, .lifr)
            } else if visibility < 3 {
                result = max(result, .ifr)
            } else if visibility <= 5 {
                result = max(result, .mvfr)
            }
        }
        if let ceiling = ceilingFeet {
            if ceiling < 500 {
                result = max(result, .lifr)
            } else if ceiling < 1_000 {
                result = max(result, .ifr)
            } else if ceiling <= 3_000 {
                result = max(result, .mvfr)
            }
        }
        return result
    }
}

public struct SkyLayer: Sendable, Equatable {
    public enum Cover: String, Sendable {
        case clear = "CLR"
        case few = "FEW"
        case scattered = "SCT"
        case broken = "BKN"
        case overcast = "OVC"
        case verticalVisibility = "VV"

        public var displayName: String {
            switch self {
            case .clear: return "Clear"
            case .few: return "Few"
            case .scattered: return "Scattered"
            case .broken: return "Broken"
            case .overcast: return "Overcast"
            case .verticalVisibility: return "Sky obscured, vertical visibility"
            }
        }
    }

    public var cover: Cover
    public var baseFeet: Int?
    /// CB (cumulonimbus) or TCU (towering cumulus), when reported.
    public var cloudType: String?

    /// Broken, overcast and vertical visibility make a ceiling.
    public var isCeiling: Bool {
        cover == .broken || cover == .overcast || cover == .verticalVisibility
    }
}

/// A decoded surface weather report (METAR, or SPECI for an unscheduled one).
public struct METARObservation: Sendable, Equatable {
    public var station: String
    public var isSpecial: Bool
    public var day: Int?
    public var hour: Int?
    public var minute: Int?
    public var isAutomated = false
    public var isCorrected = false

    /// nil for variable or unreported.
    public var windDirectionDegrees: Int?
    public var windSpeedKnots: Int?
    public var windGustKnots: Int?
    public var windIsVariable = false

    public var visibilityMiles: Double?
    /// The visibility was reported as "less than" (M1/4SM) or "more than" (P6SM).
    public var visibilityIsLessThan = false
    public var visibilityIsMoreThan = false

    /// Present-weather groups as sent (-RA, +TSRA, BR ...).
    public var weather: [String] = []
    public var sky: [SkyLayer] = []
    public var temperatureC: Int?
    public var dewpointC: Int?
    public var altimeterInHg: Double?
    public var remarks: String?

    public init(station: String, isSpecial: Bool) {
        self.station = station
        self.isSpecial = isSpecial
    }

    /// The lowest broken or overcast layer, or vertical visibility.
    public var ceilingFeet: Int? {
        sky.filter(\.isCeiling).compactMap(\.baseFeet).min()
    }

    public var flightCategory: FlightCategory {
        FlightCategory.from(visibilityMiles: visibilityMiles, ceilingFeet: ceilingFeet)
    }

    public var hasThunderstorm: Bool {
        weather.contains { $0.contains("TS") } || sky.contains { $0.cloudType == "CB" }
    }

    // MARK: Words for the UI

    public var timeLabel: String? {
        guard let day, let hour, let minute else { return nil }
        return String(format: "%02d %02d:%02dZ", day, hour, minute)
    }

    public var windSummary: String? {
        guard let speed = windSpeedKnots else { return nil }
        if speed == 0 && !windIsVariable { return "Calm" }
        var text = windIsVariable ? "Variable" : (windDirectionDegrees.map { String(format: "%03d°", $0) } ?? "Variable")
        text += " at \(speed) kt"
        if let gust = windGustKnots { text += ", gusting \(gust)" }
        return text
    }

    public var visibilitySummary: String? {
        guard let miles = visibilityMiles else { return nil }
        let number = Self.fraction(miles)
        if visibilityIsLessThan { return "Under \(number) SM" }
        if visibilityIsMoreThan { return "Over \(number) SM" }
        return "\(number) SM"
    }

    public var skySummary: String {
        if sky.isEmpty { return "Not reported" }
        return sky.map { layer in
            var text = layer.cover.displayName
            if let base = layer.baseFeet, layer.cover != .clear { text += " \(Self.thousands(base))" }
            if let type = layer.cloudType { text += " (\(type == "CB" ? "cumulonimbus" : "towering cumulus"))" }
            return text
        }.joined(separator: ", ")
    }

    public var temperatureSummary: String? {
        guard let temperatureC else { return nil }
        var text = "\(temperatureC)°C"
        if let dewpointC { text += ", dew point \(dewpointC)°C" }
        return text
    }

    public var altimeterSummary: String? {
        altimeterInHg.map { String(format: "%.2f inHg", $0) }
    }

    public var weatherSummary: String? {
        weather.isEmpty ? nil : weather.map(METARDecoder.describeWeather).joined(separator: ", ")
    }

    private static func fraction(_ miles: Double) -> String {
        let whole = Int(miles)
        let part = miles - Double(whole)
        let names: [(Double, String)] = [(0.25, "1/4"), (0.5, "1/2"), (0.75, "3/4"), (0.125, "1/8"), (0.375, "3/8"),
                                         (0.625, "5/8"), (0.0625, "1/16")]
        if part < 0.001 { return "\(whole)" }
        for (value, name) in names where abs(part - value) < 0.001 {
            return whole == 0 ? name : "\(whole) \(name)"
        }
        return String(format: "%.1f", miles)
    }

    private static func thousands(_ feet: Int) -> String {
        feet >= 1_000 ? String(format: "%d,%03d ft", feet / 1_000, feet % 1_000) : "\(feet) ft"
    }
}

public enum METARDecoder {
    /// Decodes a METAR or SPECI. Returns nil when the text is not a surface observation (no station ID).
    public static func decode(_ text: String) -> METARObservation? {
        var tokens = text.uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map(String.init)
        if let last = tokens.last, last.hasSuffix("=") {
            let trimmed = String(last.dropLast())
            if trimmed.isEmpty { tokens.removeLast() } else { tokens[tokens.count - 1] = trimmed }
        }
        guard !tokens.isEmpty else { return nil }

        var index = 0
        var special = false
        if tokens[0] == "METAR" || tokens[0] == "SPECI" {
            special = tokens[0] == "SPECI"
            index = 1
        }
        guard index < tokens.count, isStationIdentifier(tokens[index]) else { return nil }
        var observation = METARObservation(station: tokens[index], isSpecial: special)
        index += 1

        if index < tokens.count, let time = parseTime(tokens[index]) {
            observation.day = time.day
            observation.hour = time.hour
            observation.minute = time.minute
            index += 1
        }

        while index < tokens.count {
            let token = tokens[index]
            if token == "RMK" {
                observation.remarks = tokens[(index + 1)...].joined(separator: " ")
                break
            }
            if token == "AUTO" {
                observation.isAutomated = true
            } else if token == "COR" {
                observation.isCorrected = true
            } else if let wind = parseWind(token) {
                observation.windDirectionDegrees = wind.direction
                observation.windIsVariable = wind.direction == nil
                observation.windSpeedKnots = wind.speed
                observation.windGustKnots = wind.gust
            } else if isWindVariation(token) {
                // The range a variable wind swings over; the summary keeps the mean direction.
            } else if token == "CAVOK" {
                observation.visibilityMiles = 6.2137
                observation.visibilityIsMoreThan = true
            } else if let visibility = parseVisibility(tokens, at: index) {
                observation.visibilityMiles = visibility.miles
                observation.visibilityIsLessThan = visibility.lessThan
                observation.visibilityIsMoreThan = visibility.moreThan
                index += visibility.consumed - 1
            } else if let layer = parseSky(token) {
                observation.sky.append(layer)
            } else if let temperatures = parseTemperature(token) {
                observation.temperatureC = temperatures.temperature
                observation.dewpointC = temperatures.dewpoint
            } else if let altimeter = parseAltimeter(token) {
                observation.altimeterInHg = altimeter
            } else if isPresentWeather(token) {
                observation.weather.append(token)
            }
            index += 1
        }
        return observation
    }

    // MARK: Groups

    private static func isStationIdentifier(_ token: String) -> Bool {
        guard token.count == 4, let first = token.first, first.isLetter else { return false }
        return token.allSatisfy { $0.isUppercase || $0.isNumber } && token.contains { $0.isLetter }
    }

    private static func parseTime(_ token: String) -> (day: Int, hour: Int, minute: Int)? {
        guard token.count == 7, token.hasSuffix("Z") else { return nil }
        let digits = Array(token.dropLast())
        guard digits.allSatisfy(\.isNumber),
              let day = Int(String(digits[0..<2])), let hour = Int(String(digits[2..<4])),
              let minute = Int(String(digits[4..<6])) else { return nil }
        return (day, hour, minute)
    }

    private static func parseWind(_ token: String) -> (direction: Int?, speed: Int, gust: Int?)? {
        var body: String
        var factor = 1.0
        if token.hasSuffix("KT") {
            body = String(token.dropLast(2))
        } else if token.hasSuffix("MPS") {
            body = String(token.dropLast(3))
            factor = 1.94384
        } else {
            return nil
        }
        guard body.count >= 5 else { return nil }
        let directionText = String(body.prefix(3))
        var direction: Int?
        if directionText != "VRB" {
            guard let value = Int(directionText) else { return nil }
            direction = value
        }
        body = String(body.dropFirst(3))
        let parts = body.split(separator: "G", omittingEmptySubsequences: false).map(String.init)
        guard let rawSpeed = Int(parts[0]) else { return nil }
        var gust: Int?
        if parts.count > 1 {
            guard let rawGust = Int(parts[1]) else { return nil }
            gust = Int((Double(rawGust) * factor).rounded())
        }
        return (direction, Int((Double(rawSpeed) * factor).rounded()), gust)
    }

    /// "280V350".
    private static func isWindVariation(_ token: String) -> Bool {
        let characters = Array(token)
        return characters.count == 7 && characters[3] == "V"
            && characters[0..<3].allSatisfy(\.isNumber) && characters[4..<7].allSatisfy(\.isNumber)
    }

    /// Statute-mile visibility ("10SM", "1/2SM", "M1/4SM", "P6SM", "1 1/2SM") or, for reports from outside the US,
    /// four digits of metres. `consumed` is the number of tokens used.
    private static func parseVisibility(_ tokens: [String], at index: Int)
        -> (miles: Double, lessThan: Bool, moreThan: Bool, consumed: Int)? {
        let token = tokens[index]
        if token.hasSuffix("SM") {
            var body = String(token.dropLast(2))
            var lessThan = false
            var moreThan = false
            if body.hasPrefix("M") { lessThan = true; body.removeFirst() }
            if body.hasPrefix("P") { moreThan = true; body.removeFirst() }
            guard let value = parseFraction(body) else { return nil }
            return (value, lessThan, moreThan, 1)
        }
        // "1 1/2SM": a whole number, then a fraction in statute miles.
        if token.count <= 2, let whole = Int(token), index + 1 < tokens.count,
           tokens[index + 1].hasSuffix("SM"), tokens[index + 1].contains("/") {
            let fractionText = String(tokens[index + 1].dropLast(2))
            if let fraction = parseFraction(fractionText) { return (Double(whole) + fraction, false, false, 2) }
        }
        if token.count == 4, token.allSatisfy(\.isNumber), let metres = Double(token) {
            return (metres / 1_609.344, false, metres >= 9_999, 1)
        }
        return nil
    }

    private static func parseFraction(_ text: String) -> Double? {
        if let slash = text.firstIndex(of: "/") {
            guard let top = Double(text[text.startIndex..<slash]),
                  let bottom = Double(text[text.index(after: slash)...]), bottom != 0 else { return nil }
            return top / bottom
        }
        return Double(text)
    }

    private static func parseSky(_ token: String) -> SkyLayer? {
        if token == "CLR" || token == "SKC" || token == "NSC" || token == "NCD" {
            return SkyLayer(cover: .clear, baseFeet: nil, cloudType: nil)
        }
        for cover in [SkyLayer.Cover.few, .scattered, .broken, .overcast, .verticalVisibility] {
            guard token.hasPrefix(cover.rawValue) else { continue }
            let rest = token.dropFirst(cover.rawValue.count)
            guard rest.count >= 3, let hundreds = Int(rest.prefix(3)) else { continue }
            let suffix = String(rest.dropFirst(3))
            guard suffix.isEmpty || suffix == "CB" || suffix == "TCU" else { continue }
            return SkyLayer(cover: cover, baseFeet: hundreds * 100, cloudType: suffix.isEmpty ? nil : suffix)
        }
        return nil
    }

    /// "15/12", "M02/M05", "15/".
    private static func parseTemperature(_ token: String) -> (temperature: Int, dewpoint: Int?)? {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let temperature = parseTemperatureValue(parts[0]) else { return nil }
        if parts[1].isEmpty { return (temperature, nil) }
        guard let dewpoint = parseTemperatureValue(parts[1]) else { return nil }
        return (temperature, dewpoint)
    }

    private static func parseTemperatureValue(_ text: String) -> Int? {
        var digits = Substring(text)
        var negative = false
        if digits.hasPrefix("M") { negative = true; digits = digits.dropFirst() }
        guard (1...2).contains(digits.count), let value = Int(digits) else { return nil }
        return negative ? -value : value
    }

    /// "A2992" (inches of mercury) or "Q1013" (hectopascals).
    private static func parseAltimeter(_ token: String) -> Double? {
        guard token.count == 5, let first = token.first, let value = Double(token.dropFirst()) else { return nil }
        if first == "A" { return value / 100 }
        if first == "Q" { return value * 0.02953 }
        return nil
    }

    private static let descriptors: Set<String> = ["MI", "PR", "BC", "DR", "BL", "SH", "TS", "FZ"]
    private static let phenomena: Set<String> = [
        "DZ", "RA", "SN", "SG", "IC", "PL", "GR", "GS", "UP", "BR", "FG", "FU", "VA", "DU", "SA", "HZ", "PY", "PO",
        "SQ", "FC", "SS", "DS",
    ]

    private static func isPresentWeather(_ token: String) -> Bool {
        var body = Substring(token)
        if body.hasPrefix("+") || body.hasPrefix("-") { body = body.dropFirst() }
        if body.hasPrefix("VC") { body = body.dropFirst(2) }
        guard body.count >= 2, body.count % 2 == 0 else { return false }
        var rest = body
        while !rest.isEmpty {
            let code = String(rest.prefix(2))
            guard descriptors.contains(code) || phenomena.contains(code) else { return false }
            rest = rest.dropFirst(2)
        }
        return true
    }

    private static let weatherWords: [String: String] = [
        "MI": "shallow", "PR": "partial", "BC": "patches of", "DR": "low drifting", "BL": "blowing",
        "FZ": "freezing", "DZ": "drizzle", "RA": "rain", "SN": "snow", "SG": "snow grains",
        "IC": "ice crystals", "PL": "ice pellets", "GR": "hail", "GS": "small hail", "UP": "unknown precipitation",
        "BR": "mist", "FG": "fog", "FU": "smoke", "VA": "volcanic ash", "DU": "dust", "SA": "sand", "HZ": "haze",
        "PY": "spray", "PO": "dust whirls", "SQ": "squalls", "FC": "funnel cloud", "SS": "sandstorm", "DS": "duststorm",
    ]

    /// "+TSRA" becomes "heavy thunderstorm with rain"; "-SHRA" becomes "light rain showers".
    public static func describeWeather(_ token: String) -> String {
        var body = Substring(token)
        var intensity = ""
        if body.hasPrefix("+") {
            intensity = "heavy "
            body = body.dropFirst()
        } else if body.hasPrefix("-") {
            intensity = "light "
            body = body.dropFirst()
        }
        var vicinity = false
        if body.hasPrefix("VC") {
            vicinity = true
            body = body.dropFirst(2)
        }
        var codes: [String] = []
        var rest = body
        while rest.count >= 2 {
            codes.append(String(rest.prefix(2)))
            rest = rest.dropFirst(2)
        }
        let thunder = codes.contains("TS")
        let showers = codes.contains("SH")
        let others = codes.filter { $0 != "TS" && $0 != "SH" }.map { weatherWords[$0] ?? $0.lowercased() }
        var text = others.joined(separator: " ")
        if thunder {
            text = text.isEmpty ? "thunderstorm" : "thunderstorm with " + text
        } else if showers {
            text = text.isEmpty ? "showers" : text + " showers"
        }
        return intensity + text + (vicinity ? " in the vicinity" : "")
    }
}

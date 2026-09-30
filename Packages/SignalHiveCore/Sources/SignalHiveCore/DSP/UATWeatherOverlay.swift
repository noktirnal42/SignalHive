import Foundation
import CoreLocation

public enum UATWeatherKind: String, Sendable, Codable, CaseIterable {
    case metar
    case taf
    case pirep
    case sigmet
    case convectiveSigmet
    case centerWeatherAdvisory
    case airmet
    case notam
    case specialUseAirspace
    case windsAloft
    case generic

    public var displayName: String {
        switch self {
        case .metar: return "METAR"
        case .taf: return "TAF"
        case .pirep: return "PIREP"
        case .sigmet: return "SIGMET"
        case .convectiveSigmet: return "Convective SIGMET"
        case .centerWeatherAdvisory: return "CWA"
        case .airmet: return "AIRMET"
        case .notam: return "NOTAM"
        case .specialUseAirspace: return "TFR / SUA"
        case .windsAloft: return "Winds Aloft"
        case .generic: return "FIS-B"
        }
    }

    public var symbolName: String {
        switch self {
        case .metar: return "cloud.sun.fill"
        case .taf: return "cloud.fill"
        case .pirep: return "airplane.circle"
        case .sigmet: return "exclamationmark.triangle.fill"
        case .convectiveSigmet: return "cloud.bolt.rain.fill"
        case .centerWeatherAdvisory: return "text.bubble.fill"
        case .airmet: return "wind"
        case .notam: return "info.circle.fill"
        case .specialUseAirspace: return "shield.lefthalf.filled"
        case .windsAloft: return "wind.circle.fill"
        case .generic: return "cloud.drizzle.fill"
        }
    }

    public var accentName: String {
        switch self {
        case .metar: return "cyan"
        case .taf: return "indigo"
        case .pirep: return "orange"
        case .sigmet: return "red"
        case .convectiveSigmet: return "pink"
        case .centerWeatherAdvisory: return "purple"
        case .airmet: return "yellow"
        case .notam: return "mint"
        case .specialUseAirspace: return "brown"
        case .windsAloft: return "blue"
        case .generic: return "teal"
        }
    }

    public init(product: UATWeatherProduct) {
        let text = product.text.uppercased()
        let isFlightRestrictionNotice =
            text.hasPrefix("TFR") ||
            text.hasPrefix("SUA") ||
            text.contains(" TEMPORARY FLIGHT RESTRICTION") ||
            text.contains(" FLIGHT RESTRICTION") ||
            text.contains(" SPECIAL USE AIRSPACE")

        if text.hasPrefix("METAR") || text.hasPrefix("SPECI") || product.productID == 413 {
            self = .metar
        } else if text.hasPrefix("TAF") || product.productID == 8 {
            self = .taf
        } else if text.hasPrefix("PIREP") || text.contains(" UA ") || text.contains(" UUA ") || product.productID == 11 {
            self = .pirep
        } else if text.hasPrefix("CONVECTIVE SIGMET") || product.productID == 13 {
            self = .convectiveSigmet
        } else if text.hasPrefix("CENTER WEATHER ADVISORY") || text.hasPrefix("CWA") {
            self = .centerWeatherAdvisory
        } else if text.hasPrefix("SIGMET") || product.productID == 12 {
            self = .sigmet
        } else if text.hasPrefix("WINDS") ||
                    text.hasPrefix("WINDS ALOFT") ||
                    text.hasPrefix("FD ") ||
                    text.hasPrefix("FB ") {
            self = .windsAloft
        } else if text.hasPrefix("AIRMET") || text.hasPrefix("AWW") || product.productID == 14 {
            self = .airmet
        } else if isFlightRestrictionNotice {
            self = .specialUseAirspace
        } else if text.hasPrefix("NOTAM") || product.productID == 15 {
            self = .notam
        } else {
            self = .generic
        }
    }
}

public extension UATWeatherProduct {
    var kind: UATWeatherKind {
        UATWeatherKind(product: self)
    }

    var normalizedStation: String {
        let trimmedStation = station.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStation.isEmpty {
            return trimmedStation
        }

        return Self.inferredStation(fromText: text, kind: kind) ?? ""
    }

    static func inferredStation(fromText text: String, kind: UATWeatherKind) -> String? {
        let tokens = stationTokens(fromText: text)

        guard !tokens.isEmpty else { return nil }

        switch kind {
        case .metar, .taf:
            return firstStation(
                in: tokens,
                skipping: [
                    "METAR", "SPECI", "TAF",
                    "AMD", "COR", "AUTO", "RTD",
                    "CCA", "CCB", "CCC"
                ]
            )
        case .pirep:
            return firstStation(
                in: tokens,
                skipping: [
                    "PIREP", "UA", "UUA",
                    "OV", "TM", "FL", "OBS", "AT"
                ]
            )
        case .notam:
            return firstStation(
                in: tokens,
                skipping: [
                    "NOTAM", "NOTAMD", "D", "FDC",
                    "RWY", "TWY", "APRON", "AIRSPACE",
                    "TFR", "SUA", "SPECIAL", "USE",
                    "TEMPORARY", "FLIGHT", "RESTRICTION",
                    "PART", "OF", "FOR", "AND", "AT",
                    "VALID", "UNTIL", "ACTIVE", "AREA"
                ]
            )
        case .sigmet, .convectiveSigmet, .centerWeatherAdvisory:
            return firstStation(
                in: tokens,
                skipping: [
                    "SIGMET", "CONVECTIVE", "CENTER",
                    "WEATHER", "ADVISORY", "CWA",
                    "VALID", "AREA", "FOR", "OBS",
                    "SEV", "TS", "EMBD", "SQL",
                    "LINE", "FROM", "TO", "BTN",
                    "ABV", "BLW", "AND", "WST",
                    "WS", "OCNL", "FRQ"
                ]
            )
        case .windsAloft:
            return firstStation(
                in: tokens,
                skipping: [
                    "WINDS", "ALOFT", "FD", "FB",
                    "VALID", "FOR", "TEMPS",
                    "TEMP", "AND", "ABV", "BLW"
                ]
            )
        case .airmet:
            return firstStation(
                in: tokens,
                skipping: [
                    "AIRMET", "AWW", "SIERRA",
                    "TANGO", "ZULU", "UPDT",
                    "UPDATE", "VALID", "FOR",
                    "IFR", "MTN", "OBSCN",
                    "TURB", "ICE", "LLWS",
                    "STG", "SUST", "WIND",
                    "BLW", "ABV", "BTN", "AND"
                ]
            )
        case .specialUseAirspace:
            return firstStation(
                in: tokens,
                skipping: [
                    "TFR", "SUA", "NOTAM", "NOTAMD",
                    "D", "FDC", "SPECIAL", "USE",
                    "AIRSPACE", "TEMPORARY", "FLIGHT",
                    "RESTRICTION", "ACTIVE", "AREA",
                    "PART", "OF", "RADIUS", "NM",
                    "FROM", "TO", "FOR", "AND"
                ]
            )
        case .generic:
            return nil
        }
    }

    private static func stationTokens(fromText text: String) -> [String] {
        text
            .uppercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func firstStation(in tokens: [String], skipping skipTokens: Set<String>) -> String? {
        for token in tokens where !skipTokens.contains(token) {
            if let station = normalizeStationToken(token) {
                return station
            }
        }
        return nil
    }

    private static func normalizeStationToken(_ token: String) -> String? {
        let uppercased = token.uppercased()
        guard uppercased.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        guard (3...4).contains(uppercased.count) else { return nil }
        guard uppercased.contains(where: \.isLetter) else { return nil }
        return uppercased
    }
}

public struct UATWeatherOverlayPoint: Identifiable, Sendable, Hashable {
    public let id: String
    public let productID: Int
    public let station: String
    public let timestamp: Date
    public let coordinate: CLLocationCoordinate2D
    public let kind: UATWeatherKind
    public let title: String
    public let subtitle: String

    public init?(product: UATWeatherProduct) {
        guard let latitude = product.latitude, let longitude = product.longitude else { return nil }

        let kind = product.kind
        let station = product.normalizedStation.isEmpty ? kind.displayName : product.normalizedStation
        let subtitle = product.text.trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = "\(product.productID)-\(station)-\(product.timestamp.timeIntervalSince1970)"
        self.productID = product.productID
        self.station = station
        self.timestamp = product.timestamp
        self.coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        self.kind = kind
        self.title = station
        self.subtitle = subtitle
    }

    public static func makeMapPoints(from products: [UATWeatherProduct], maxCount: Int = 100) -> [UATWeatherOverlayPoint] {
        var seen: Set<String> = []
        var points: [UATWeatherOverlayPoint] = []

        for product in products.sorted(by: { $0.timestamp > $1.timestamp }) {
            guard let point = UATWeatherOverlayPoint(product: product) else { continue }
            let dedupeKey = [
                point.station,
                point.kind.rawValue,
                String(format: "%.3f", point.coordinate.latitude),
                String(format: "%.3f", point.coordinate.longitude)
            ].joined(separator: "|")

            guard seen.insert(dedupeKey).inserted else { continue }
            points.append(point)
            if points.count >= maxCount { break }
        }

        return points
    }

    public static func == (lhs: UATWeatherOverlayPoint, rhs: UATWeatherOverlayPoint) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

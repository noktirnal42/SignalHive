import Foundation

public enum AviationMessageKind: String, CaseIterable, Sendable, Codable, Hashable {
    case metar
    case taf
    case pirep
    case sigmet
    case airmet
    case advisory
    case notam
    case restriction
    case windsAloft
    case atis
    case twip
    case groundStation
    case aircraftAlert
    case receiver
    case other

    public var displayName: String {
        switch self {
        case .metar: return "METAR"
        case .taf: return "TAF"
        case .pirep: return "PIREP"
        case .sigmet: return "SIGMET"
        case .airmet: return "AIRMET"
        case .advisory: return "Advisory"
        case .notam: return "NOTAM"
        case .restriction: return "TFR / SUA"
        case .windsAloft: return "Winds aloft"
        case .atis: return "D-ATIS"
        case .twip: return "TWIP"
        case .groundStation: return "Ground station"
        case .aircraftAlert: return "Aircraft alert"
        case .receiver: return "Receiver"
        case .other: return "Other"
        }
    }

    /// An SF Symbol name.
    public var symbolName: String {
        switch self {
        case .metar: return "cloud.sun"
        case .taf: return "calendar.badge.clock"
        case .pirep: return "person.wave.2"
        case .sigmet: return "exclamationmark.triangle"
        case .airmet: return "wind"
        case .advisory: return "text.bubble"
        case .notam: return "info.circle"
        case .restriction: return "shield.lefthalf.filled"
        case .windsAloft: return "wind.circle"
        case .atis: return "speaker.wave.2"
        case .twip: return "cloud.bolt"
        case .groundStation: return "antenna.radiowaves.left.and.right"
        case .aircraftAlert: return "airplane.circle"
        case .receiver: return "dot.radiowaves.left.and.right"
        case .other: return "doc.text"
        }
    }

    /// Kinds where only the newest report for a station matters.
    public var supersedesPerStation: Bool {
        switch self {
        case .metar, .taf, .windsAloft, .atis: return true
        default: return false
        }
    }

    /// Classifies a FIS-B text report by how it starts, falling back to the product number it came in.
    public static func classify(reportText: String, productID: Int? = nil) -> AviationMessageKind {
        let text = reportText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("METAR") || text.hasPrefix("SPECI") { return .metar }
        if text.hasPrefix("TAF") { return .taf }
        if text.hasPrefix("PIREP") || text.hasPrefix("UA ") || text.hasPrefix("UUA ") { return .pirep }
        if text.hasPrefix("CONVECTIVE SIGMET") || text.hasPrefix("SIGMET") || text.hasPrefix("WS ") { return .sigmet }
        if text.hasPrefix("AIRMET") { return .airmet }
        if text.hasPrefix("CWA") || text.hasPrefix("CENTER WEATHER") || text.hasPrefix("AWW") { return .advisory }
        if text.hasPrefix("WINDS") || text.hasPrefix("FD ") || text.hasPrefix("FB ") { return .windsAloft }
        if text.hasPrefix("NOTAM-TFR") || text.hasPrefix("TFR") || text.hasPrefix("SUA") || text.hasPrefix("SPECIAL USE") {
            return .restriction
        }
        if text.hasPrefix("NOTAM") || text.hasPrefix("!") { return .notam }
        if text.hasPrefix("D-ATIS") || text.hasPrefix("ATIS") { return .atis }
        if text.hasPrefix("TWIP") { return .twip }
        switch productID {
        case 0, 20: return .metar
        case 1, 21: return .taf
        case 2, 3, 22, 23: return .sigmet
        case 4, 24, 11: return .airmet
        case 5, 25: return .pirep
        case 6, 26: return .advisory
        case 7, 27: return .windsAloft
        case 8: return .notam
        case 9: return .atis
        case 10: return .twip
        case 12: return .sigmet
        case 13: return .restriction
        default: return .other
        }
    }
}

public enum AviationSeverity: Int, Sendable, Codable, Comparable, CaseIterable {
    case info = 0
    case advisory = 1
    case warning = 2
    case critical = 3

    public var displayName: String {
        switch self {
        case .info: return "Info"
        case .advisory: return "Advisory"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    public static func < (lhs: AviationSeverity, rhs: AviationSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One item in the aviation text feed: a weather report, notice, aircraft alert or receiver event.
public struct AviationMessage: Sendable, Identifiable, Equatable {
    /// Same content gives the same ID, so a report repeated by the ground station is one row that counts its repeats.
    public let id: String
    public var kind: AviationMessageKind
    /// The airport or station the report is about, when it has one.
    public var station: String?
    public var title: String
    public var body: String
    public var severity: AviationSeverity
    /// Where it was heard: "FIS-B 978", "ADS-B 1090", "Demo", "System".
    public var origin: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var count = 1
    public var productID: Int?
    /// A decoded METAR, for surface observations.
    public var observation: METARObservation?
    public var coordinate: GeoCoordinate?

    public init(kind: AviationMessageKind, station: String? = nil, title: String, body: String,
                severity: AviationSeverity = .info, origin: String, at date: Date, productID: Int? = nil,
                observation: METARObservation? = nil, coordinate: GeoCoordinate? = nil) {
        self.kind = kind
        self.station = station
        self.title = title
        self.body = body
        self.severity = severity
        self.origin = origin
        self.firstSeen = date
        self.lastSeen = date
        self.productID = productID
        self.observation = observation
        self.coordinate = coordinate
        self.id = Self.identifier(kind: kind, station: station, body: body)
    }

    public var flightCategory: FlightCategory? { observation?.flightCategory }

    static func identifier(kind: AviationMessageKind, station: String?, body: String) -> String {
        let normalized = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").uppercased()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\(kind.rawValue)|\(station ?? "-")|" + String(hash, radix: 16)
    }

    // MARK: Builders

    /// A FIS-B text report (one record of a generic text product). METARs are decoded, stations found, and severity set.
    public static func fisbReport(_ text: String, productID: Int? = nil, at date: Date, origin: String = "FIS-B 978",
                                  coordinate: GeoCoordinate? = nil) -> AviationMessage {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = AviationMessageKind.classify(reportText: cleaned, productID: productID)
        var observation: METARObservation?
        var station: String?
        var severity = AviationSeverity.info

        switch kind {
        case .metar:
            observation = METARDecoder.decode(cleaned)
            station = observation?.station ?? stationAfterKeyword(in: cleaned, keywords: ["METAR", "SPECI"])
            if let observation {
                if observation.flightCategory >= .ifr { severity = .advisory }
                if observation.hasThunderstorm { severity = max(severity, .advisory) }
            }
        case .taf:
            station = stationAfterKeyword(in: cleaned, keywords: ["TAF", "AMD", "COR"])
        case .pirep:
            if cleaned.uppercased().hasPrefix("UUA") || cleaned.uppercased().contains(" UUA ") { severity = .warning }
        case .sigmet, .restriction:
            severity = .warning
        case .airmet, .advisory:
            severity = .advisory
        case .windsAloft, .atis, .notam, .twip:
            station = stationAfterKeyword(in: cleaned, keywords: ["WINDS", "FD", "FB", "D-ATIS", "ATIS", "NOTAM", "NOTAM-D", "NOTAM-FDC", "TWIP"])
        default:
            break
        }

        var title = kind.displayName
        if let station { title += " " + station }
        if let observation, observation.flightCategory != .unknown { title += " " + observation.flightCategory.rawValue }
        return AviationMessage(kind: kind, station: station, title: title, body: cleaned, severity: severity, origin: origin,
                               at: date, productID: productID, observation: observation, coordinate: coordinate)
    }

    /// The first token after the report type that looks like a station ID (three or four letters or digits).
    private static func stationAfterKeyword(in text: String, keywords: Set<String>) -> String? {
        let tokens = text.uppercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for token in tokens where !keywords.contains(token) {
            guard (3...4).contains(token.count), token.allSatisfy({ $0.isLetter || $0.isNumber }),
                  token.contains(where: { $0.isLetter }) else { return nil }
            return token
        }
        return nil
    }

    /// An aircraft declared an emergency or is squawking an emergency code.
    public static func aircraftAlert(_ aircraft: AircraftState, at date: Date, origin: String) -> AviationMessage? {
        var reason: String?
        var severity = AviationSeverity.warning
        if let alert = aircraft.squawkAlert {
            reason = alert.displayName
            severity = alert == .radioFailure ? .warning : .critical
        } else if let emergency = aircraft.emergency, emergency != ADSBEmergencyState.none {
            reason = emergency.label
            severity = .critical
        }
        guard let reason else { return nil }
        var body = "\(aircraft.displayName) (\(aircraft.addressHex)): \(reason)"
        if let altitude = aircraft.altitudeFeet { body += ", \(altitude) ft" }
        if let position = aircraft.coordinate { body += String(format: ", %.3f, %.3f", position.latitude, position.longitude) }
        return AviationMessage(kind: .aircraftAlert, station: aircraft.callsign.isEmpty ? nil : aircraft.callsign,
                               title: "\(aircraft.displayName): \(reason)", body: body, severity: severity, origin: origin,
                               at: date, coordinate: aircraft.coordinate)
    }
}

/// A FIS-B ground station heard in an uplink.
public struct GroundStation: Sendable, Identifiable, Equatable {
    public var id: String { String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude) }
    public var coordinate: GeoCoordinate
    public var slotID: Int
    public var firstHeard: Date
    public var lastHeard: Date
    public var uplinks: Int

    public init(coordinate: GeoCoordinate, slotID: Int, heard: Date) {
        self.coordinate = coordinate
        self.slotID = slotID
        self.firstHeard = heard
        self.lastHeard = heard
        self.uplinks = 1
    }
}

/// The messages heard so far, oldest first internally; use `newestFirst` for display.
public struct AviationMessageFeed: Sendable, Equatable {
    public private(set) var messages: [AviationMessage] = []
    public var capacity = 1_500
    /// Increases whenever anything changes.
    public private(set) var revision = 0

    public init() {}

    public var newestFirst: [AviationMessage] { messages.reversed() }

    /// Adds a message. A repeat of something already held (same kind, station and text) only refreshes it, so the ground
    /// station's constant rebroadcasts do not flood the list. Returns true when it was new.
    @discardableResult
    public mutating func add(_ message: AviationMessage) -> Bool {
        revision += 1
        if let index = messages.lastIndex(where: { $0.id == message.id }) {
            messages[index].lastSeen = max(messages[index].lastSeen, message.lastSeen)
            messages[index].count += 1
            return false
        }
        messages.append(message)
        if messages.count > capacity { messages.removeFirst(messages.count - capacity) }
        return true
    }

    public mutating func clear() {
        messages.removeAll()
        revision += 1
    }

    public func counts() -> [AviationMessageKind: Int] {
        var result: [AviationMessageKind: Int] = [:]
        for message in messages { result[message.kind, default: 0] += 1 }
        return result
    }

    /// Newest first, optionally limited to some kinds, a minimum severity, a search text, and the latest report per
    /// station for kinds where older ones are obsolete (METAR, TAF, winds aloft, D-ATIS).
    public func filtered(kinds: Set<AviationMessageKind>? = nil, minimumSeverity: AviationSeverity = .info,
                         search: String = "", latestPerStation: Bool = false) -> [AviationMessage] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var newestByStation: [String: Date] = [:]
        if latestPerStation {
            for message in messages where message.kind.supersedesPerStation {
                let key = message.kind.rawValue + "|" + (message.station ?? "")
                if message.firstSeen >= (newestByStation[key] ?? .distantPast) { newestByStation[key] = message.firstSeen }
            }
        }
        return newestFirst.filter { message in
            if let kinds, !kinds.contains(message.kind) { return false }
            if message.severity < minimumSeverity { return false }
            if latestPerStation, message.kind.supersedesPerStation, let station = message.station {
                let key = message.kind.rawValue + "|" + station
                if let newest = newestByStation[key], message.firstSeen < newest { return false }
            }
            if !needle.isEmpty {
                let haystack = (message.title + " " + message.body + " " + (message.station ?? "")).lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }
}

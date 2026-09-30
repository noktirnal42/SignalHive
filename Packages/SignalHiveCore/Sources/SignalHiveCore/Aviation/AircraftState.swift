import Foundation

/// Where a report came from.
public enum AircraftSource: String, Sendable, Codable, Hashable, CaseIterable {
    /// 1090 MHz Mode S / ADS-B.
    case modeS
    /// 978 MHz UAT, sent by the aircraft itself.
    case uat
    /// A ground station relaying traffic it sees on radar or on another link (TIS-B / ADS-R).
    case relayed
    /// The built-in demo scenario.
    case demo

    public var displayName: String {
        switch self {
        case .modeS: return "ADS-B 1090"
        case .uat: return "UAT 978"
        case .relayed: return "TIS-B / ADS-R"
        case .demo: return "Demo"
        }
    }
}

public enum AircraftFreshness: Sendable, Equatable {
    /// Heard within the last 10 seconds.
    case live
    /// Heard within the last 30 seconds.
    case recent
    /// Older; probably out of range or landed.
    case stale
}

public enum SquawkAlert: String, Sendable, Codable, Equatable {
    case hijack
    case radioFailure
    case emergency

    public init?(squawk: String) {
        switch squawk {
        case "7500": self = .hijack
        case "7600": self = .radioFailure
        case "7700": self = .emergency
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .hijack: return "Squawk 7500 (hijack)"
        case .radioFailure: return "Squawk 7600 (radio failure)"
        case .emergency: return "Squawk 7700 (emergency)"
        }
    }
}

/// A partial update about one aircraft: whatever a single message carried, nothing more.
public struct AircraftReport: Sendable {
    public var address: UInt32
    public var source: AircraftSource
    public var time: Date
    public var callsign: String?
    public var squawk: String?
    public var altitudeFeet: Int?
    public var coordinate: GeoCoordinate?
    public var groundSpeedKnots: Double?
    public var trackDegrees: Double?
    public var verticalRateFPM: Int?
    public var onGround: Bool?
    public var aircraftClass: AircraftClass?
    public var emergency: ADSBEmergencyState?
    public var signalDBFS: Double?

    public init(address: UInt32, source: AircraftSource, time: Date, callsign: String? = nil, squawk: String? = nil,
                altitudeFeet: Int? = nil, coordinate: GeoCoordinate? = nil, groundSpeedKnots: Double? = nil,
                trackDegrees: Double? = nil, verticalRateFPM: Int? = nil, onGround: Bool? = nil,
                aircraftClass: AircraftClass? = nil, emergency: ADSBEmergencyState? = nil, signalDBFS: Double? = nil) {
        self.address = address
        self.source = source
        self.time = time
        self.callsign = callsign
        self.squawk = squawk
        self.altitudeFeet = altitudeFeet
        self.coordinate = coordinate
        self.groundSpeedKnots = groundSpeedKnots
        self.trackDegrees = trackDegrees
        self.verticalRateFPM = verticalRateFPM
        self.onGround = onGround
        self.aircraftClass = aircraftClass
        self.emergency = emergency
        self.signalDBFS = signalDBFS
    }

    /// Fills in fields `other` has and this report lacks, so several messages heard within one flush interval can be
    /// sent as one report.
    public mutating func merge(_ other: AircraftReport) {
        if let value = other.callsign, !value.isEmpty { callsign = value }
        if let value = other.squawk { squawk = value }
        if let value = other.altitudeFeet { altitudeFeet = value }
        if let value = other.coordinate { coordinate = value }
        if let value = other.groundSpeedKnots { groundSpeedKnots = value }
        if let value = other.trackDegrees { trackDegrees = value }
        if let value = other.verticalRateFPM { verticalRateFPM = value }
        if let value = other.onGround { onGround = value }
        if let value = other.aircraftClass { aircraftClass = value }
        if let value = other.emergency { emergency = value }
        if let value = other.signalDBFS { signalDBFS = value }
        if other.time > time { time = other.time }
    }
}

/// Everything known about one aircraft.
public struct AircraftState: Sendable, Identifiable, Equatable {
    public var id: UInt32 { address }
    public let address: UInt32
    public var callsign = ""
    public var squawk = ""
    public var altitudeFeet: Int?
    public var coordinate: GeoCoordinate?
    public var groundSpeedKnots: Double?
    public var trackDegrees: Double?
    public var verticalRateFPM: Int?
    public var onGround = false
    public var aircraftClass = AircraftClass.unknown
    /// The class was guessed (from the flight ID and speed) rather than broadcast.
    public var classIsInferred = false
    public var emergency: ADSBEmergencyState?
    public var sources: Set<AircraftSource> = []
    public var messageCount = 0
    public var firstSeen: Date
    public var lastSeen: Date
    public var lastPositionTime: Date?
    public var signalDBFS: Double?
    public var history = TrackHistory()

    public init(address: UInt32, firstSeen: Date) {
        self.address = address
        self.firstSeen = firstSeen
        self.lastSeen = firstSeen
    }

    public var addressHex: String { String(format: "%06X", address) }

    /// What to call it on the map: flight ID, else the ICAO address.
    public var displayName: String { callsign.isEmpty ? addressHex : callsign }

    public var iconKind: AircraftIconKind {
        AircraftIconKind(class: aircraftClass, groundSpeedKnots: groundSpeedKnots, altitudeFeet: altitudeFeet)
    }

    public var color: RGB8 {
        AltitudeColorScale.color(altitudeFeet: altitudeFeet, onGround: onGround)
    }

    public var squawkAlert: SquawkAlert? { SquawkAlert(squawk: squawk) }

    /// A declared emergency, or one of the emergency squawk codes.
    public var isEmergency: Bool {
        if let emergency, emergency != ADSBEmergencyState.none { return true }
        return squawkAlert != nil
    }

    public var country: String? { ICAOAddressBlocks.country(for: address) }
    public var isLikelyUSMilitary: Bool { ICAOAddressBlocks.isUSMilitary(address) }

    public func freshness(now: Date) -> AircraftFreshness {
        let age = now.timeIntervalSince(lastSeen)
        if age <= 10 { return .live }
        if age <= 30 { return .recent }
        return .stale
    }

    mutating func merge(_ report: AircraftReport) {
        messageCount += 1
        sources.insert(report.source)
        if report.time > lastSeen { lastSeen = report.time }
        if let value = report.callsign?.trimmingCharacters(in: .whitespaces), !value.isEmpty { callsign = value }
        if let value = report.squawk { squawk = value }
        if let value = report.altitudeFeet { altitudeFeet = value }
        if let value = report.groundSpeedKnots { groundSpeedKnots = value }
        if let value = report.trackDegrees { trackDegrees = value }
        if let value = report.verticalRateFPM { verticalRateFPM = value }
        if let value = report.onGround { onGround = value }
        if let value = report.emergency { emergency = value == ADSBEmergencyState.none ? nil : value }
        if let value = report.signalDBFS { signalDBFS = value }

        if let broadcast = report.aircraftClass, broadcast != .unknown {
            aircraftClass = broadcast
            classIsInferred = false
        } else if aircraftClass == .unknown || classIsInferred {
            let guess = AircraftClass.inferred(callsign: callsign, groundSpeedKnots: groundSpeedKnots, altitudeFeet: altitudeFeet)
            if guess != .unknown {
                aircraftClass = guess
                classIsInferred = true
            }
        }
        if !aircraftClass.isAircraft { onGround = true }
    }
}

/// The 24-bit ICAO address space is handed to countries in blocks (ICAO Annex 10, Volume III).
public enum ICAOAddressBlocks {
    private struct Block {
        var first: UInt32
        var last: UInt32
        var country: String
    }

    private static let blocks: [Block] = [
        Block(first: 0x0D0000, last: 0x0D7FFF, country: "Mexico"),
        Block(first: 0x300000, last: 0x33FFFF, country: "Italy"),
        Block(first: 0x340000, last: 0x37FFFF, country: "Spain"),
        Block(first: 0x380000, last: 0x3BFFFF, country: "France"),
        Block(first: 0x3C0000, last: 0x3FFFFF, country: "Germany"),
        Block(first: 0x400000, last: 0x43FFFF, country: "United Kingdom"),
        Block(first: 0x480000, last: 0x487FFF, country: "Netherlands"),
        Block(first: 0x7C0000, last: 0x7FFFFF, country: "Australia"),
        Block(first: 0x840000, last: 0x87FFFF, country: "Japan"),
        Block(first: 0xA00000, last: 0xAFFFFF, country: "United States"),
        Block(first: 0xC00000, last: 0xC3FFFF, country: "Canada"),
        Block(first: 0xE40000, last: 0xE7FFFF, country: "Brazil"),
    ]

    /// The registering country for the blocks listed above; nil for any other address.
    public static func country(for address: UInt32) -> String? {
        blocks.first { address >= $0.first && address <= $0.last }?.country
    }

    /// The part of the US block allocated to the military.
    public static func isUSMilitary(_ address: UInt32) -> Bool {
        address >= 0xADF7C8 && address <= 0xAFFFFF
    }
}

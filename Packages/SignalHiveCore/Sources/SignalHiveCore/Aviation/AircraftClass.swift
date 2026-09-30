import Foundation

/// What kind of aircraft (or ground vehicle or obstacle) a transponder says it is.
///
/// ADS-B and UAT both send an "emitter category". It is optional and often left at "no information", so a class can
/// also be inferred from other things an aircraft broadcasts; `AircraftState.classIsInferred` records which happened.
public enum AircraftClass: String, CaseIterable, Sendable, Codable {
    case light
    case small
    case large
    case highVortexLarge
    case heavy
    case highPerformance
    case rotorcraft
    case glider
    case lighterThanAir
    case parachutist
    case ultralight
    case uav
    case spaceVehicle
    case surfaceEmergency
    case surfaceService
    case pointObstacle
    case clusterObstacle
    case lineObstacle
    case unknown

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .small: return "Small"
        case .large: return "Large"
        case .highVortexLarge: return "High-vortex large"
        case .heavy: return "Heavy"
        case .highPerformance: return "High performance"
        case .rotorcraft: return "Rotorcraft"
        case .glider: return "Glider"
        case .lighterThanAir: return "Balloon / airship"
        case .parachutist: return "Parachutist"
        case .ultralight: return "Ultralight / hang glider"
        case .uav: return "Drone (UAV)"
        case .spaceVehicle: return "Space vehicle"
        case .surfaceEmergency: return "Emergency vehicle"
        case .surfaceService: return "Service vehicle"
        case .pointObstacle: return "Obstacle"
        case .clusterObstacle: return "Obstacle cluster"
        case .lineObstacle: return "Line obstacle"
        case .unknown: return "Unknown"
        }
    }

    /// The weight or role band the category stands for, as the ADS-B specification defines it.
    public var detail: String {
        switch self {
        case .light: return "Under 15,500 lb"
        case .small: return "15,500 to 75,000 lb"
        case .large: return "75,000 to 300,000 lb"
        case .highVortexLarge: return "Like the Boeing 757, strong wake vortices"
        case .heavy: return "Over 300,000 lb"
        case .highPerformance: return "Over 5 g and 400 kt"
        case .rotorcraft: return "Helicopter or other rotorcraft"
        case .glider: return "Glider or sailplane"
        case .lighterThanAir: return "Balloon or airship"
        case .parachutist: return "Parachutist or skydiver"
        case .ultralight: return "Ultralight, hang glider or paraglider"
        case .uav: return "Unmanned aerial vehicle"
        case .spaceVehicle: return "Space or trans-atmospheric vehicle"
        case .surfaceEmergency: return "Surface emergency vehicle"
        case .surfaceService: return "Surface service vehicle"
        case .pointObstacle: return "Fixed obstacle"
        case .clusterObstacle: return "Cluster of obstacles"
        case .lineObstacle: return "Line of obstacles, such as power lines"
        case .unknown: return "No category received"
        }
    }

    /// True for things that fly (as opposed to surface vehicles and obstacles).
    public var isAircraft: Bool {
        switch self {
        case .surfaceEmergency, .surfaceService, .pointObstacle, .clusterObstacle, .lineObstacle: return false
        default: return true
        }
    }

    // MARK: From what is broadcast

    /// ADS-B (Mode S extended squitter): the type code of the identification message (4 = set A, 3 = set B,
    /// 2 = set C) and its 3-bit category.
    public static func fromADSB(typeCode: Int, category: Int) -> AircraftClass {
        switch (typeCode, category) {
        case (4, 1): return .light
        case (4, 2): return .small
        case (4, 3): return .large
        case (4, 4): return .highVortexLarge
        case (4, 5): return .heavy
        case (4, 6): return .highPerformance
        case (4, 7): return .rotorcraft
        case (3, 1): return .glider
        case (3, 2): return .lighterThanAir
        case (3, 3): return .parachutist
        case (3, 4): return .ultralight
        case (3, 6): return .uav
        case (3, 7): return .spaceVehicle
        case (2, 1): return .surfaceEmergency
        case (2, 2): return .surfaceService
        case (2, 3): return .pointObstacle
        case (2, 4): return .clusterObstacle
        case (2, 5): return .lineObstacle
        default: return .unknown
        }
    }

    /// UAT (978 MHz): the emitter category, 0 ... 39, numbered as in DO-282B.
    public static func fromUAT(emitterCategory: Int) -> AircraftClass {
        switch emitterCategory {
        case 1: return .light
        case 2: return .small
        case 3: return .large
        case 4: return .highVortexLarge
        case 5: return .heavy
        case 6: return .highPerformance
        case 7: return .rotorcraft
        case 9: return .glider
        case 10: return .lighterThanAir
        case 11: return .parachutist
        case 12: return .ultralight
        case 14: return .uav
        case 15: return .spaceVehicle
        case 17: return .surfaceEmergency
        case 18: return .surfaceService
        case 19: return .pointObstacle
        case 20: return .clusterObstacle
        case 21: return .lineObstacle
        default: return .unknown
        }
    }

    /// A best guess when no category was sent, from the flight ID and the speed and height reached.
    ///
    /// Airline flight IDs are a three-letter operator code and digits ("UAL123"), so those are airliners. US
    /// registrations used as flight IDs ("N123AB") are mostly general aviation. Fast and high with no other clue is a
    /// jet. Anything else stays `.unknown` rather than being guessed.
    public static func inferred(callsign: String?, groundSpeedKnots: Double?, altitudeFeet: Int?) -> AircraftClass {
        let id = (callsign ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        let characters = Array(id)
        if characters.count >= 4, characters.count <= 7,
           characters[0...2].allSatisfy({ $0.isLetter }),
           characters[3].isNumber,
           characters[3...].contains(where: { $0.isNumber }) {
            return .large
        }
        if characters.count >= 3, characters[0] == "N", characters[1].isNumber,
           characters.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return .light
        }
        if let speed = groundSpeedKnots, let altitude = altitudeFeet, speed >= 350, altitude >= 20_000 {
            return .large
        }
        return .unknown
    }
}

/// Which painted icon stands for an aircraft. It is the class, except that "small" aircraft are drawn as a
/// business jet when they fly like one, and as a twin turboprop otherwise.
public enum AircraftIconKind: String, CaseIterable, Sendable {
    case light
    case small
    case bizjet
    case large
    case highVortexLarge
    case heavy
    case highPerformance
    case rotorcraft
    case glider
    case lighterThanAir
    case parachutist
    case ultralight
    case uav
    case spaceVehicle
    case surfaceEmergency
    case surfaceService
    case pointObstacle
    case clusterObstacle
    case lineObstacle
    case unknown

    public init(class aircraftClass: AircraftClass, groundSpeedKnots: Double? = nil, altitudeFeet: Int? = nil) {
        switch aircraftClass {
        case .small:
            let fast = (groundSpeedKnots ?? 0) >= 250 || (altitudeFeet ?? 0) >= 25_000
            self = fast ? .bizjet : .small
        case .light: self = .light
        case .large: self = .large
        case .highVortexLarge: self = .highVortexLarge
        case .heavy: self = .heavy
        case .highPerformance: self = .highPerformance
        case .rotorcraft: self = .rotorcraft
        case .glider: self = .glider
        case .lighterThanAir: self = .lighterThanAir
        case .parachutist: self = .parachutist
        case .ultralight: self = .ultralight
        case .uav: self = .uav
        case .spaceVehicle: self = .spaceVehicle
        case .surfaceEmergency: self = .surfaceEmergency
        case .surfaceService: self = .surfaceService
        case .pointObstacle: self = .pointObstacle
        case .clusterObstacle: self = .clusterObstacle
        case .lineObstacle: self = .lineObstacle
        case .unknown: self = .unknown
        }
    }

    /// The painted layers of this icon (see `AircraftIconPart`).
    public var parts: [AircraftIconPart] {
        AircraftIconData.parts[rawValue] ?? []
    }
}

// MARK: - Icon geometry types

/// One painted layer of an aircraft icon, in a unit square (x right, y down, nose at y = -1). The app's icon
/// renderer decides how each `Paint` looks; the geometry itself is generated by `script/generate_aircraft_icons.py`.
public struct AircraftIconPart: Sendable, Equatable {
    public enum Paint: String, Sendable {
        /// The main color (altitude).
        case body
        /// A darker shade: tail planes, cargo boxes.
        case dark
        /// A lighter shade: engines, light bars.
        case light
        /// Cockpit glass and other dark details.
        case glass
        /// A translucent white sheen.
        case highlight
        /// A translucent disc: a rotor or propeller in motion.
        case disc
        /// A stroked line: rotor blades, rigging, wires.
        case line
    }

    public enum Shape: Sendable, Equatable {
        /// Vertices as x0, y0, x1, y1, ...
        case polygon([Double])
        case ellipse(cx: Double, cy: Double, rx: Double, ry: Double)
        case line(x1: Double, y1: Double, x2: Double, y2: Double, width: Double)
    }

    public var paint: Paint
    public var shape: Shape

    static func polygon(_ paint: Paint, _ xy: [Double]) -> AircraftIconPart {
        AircraftIconPart(paint: paint, shape: .polygon(xy))
    }

    static func ellipse(_ paint: Paint, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> AircraftIconPart {
        AircraftIconPart(paint: paint, shape: .ellipse(cx: cx, cy: cy, rx: rx, ry: ry))
    }

    static func line(_ paint: Paint, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ width: Double) -> AircraftIconPart {
        AircraftIconPart(paint: paint, shape: .line(x1: x1, y1: y1, x2: x2, y2: y2, width: width))
    }
}

import Foundation

/// A short, deterministic digest of what the receivers have heard: how much traffic, who is declaring an emergency, how
/// the weather looks, which hazard products are active. It states only what the picture holds, so it is useful with no
/// model at all, and it is the set of facts a model's briefing is held to.
public struct AviationBriefing: Equatable, Sendable {
    /// Aircraft not heard for this long are not "tracked" (the same cut-off the picture's own expiry uses).
    public static let aircraftTimeout: TimeInterval = 120

    public struct Extreme: Equatable, Sendable {
        public var name: String
        public var value: Double
    }

    public struct Traffic: Equatable, Sendable {
        public var tracked = 0
        public var airborne = 0
        public var onGround = 0
        public var withPosition = 0
        /// Aircraft heard by each source, by the source's display name.
        public var bySource: [String: Int] = [:]
        public var highest: Extreme?
        public var fastest: Extreme?
        public var farthest: Extreme?
    }

    public struct Emergency: Equatable, Sendable {
        public var name: String
        public var reason: String
    }

    public struct Weather: Equatable, Sendable {
        public struct Ceiling: Equatable, Sendable {
            public var station: String
            public var feet: Int
        }
        public struct Wind: Equatable, Sendable {
            public var station: String
            public var knots: Int
            public var isGust: Bool
        }

        public var stations = 0
        public var byCategory: [FlightCategory: Int] = [:]
        public var worstCategory: FlightCategory?
        public var worstStations: [String] = []
        public var thunderstormStations: [String] = []
        public var lowestCeiling: Ceiling?
        public var strongestWind: Wind?
    }

    public struct Hazards: Equatable, Sendable {
        public var sigmets = 0
        public var airmets = 0
        public var advisories = 0
        public var restrictions = 0
        /// Titles of warning-level products, newest first.
        public var urgent: [String] = []

        var total: Int { sigmets + airmets + advisories + restrictions }
    }

    public var generatedAt: Date
    public var traffic: Traffic
    public var emergencies: [Emergency]
    public var weather: Weather
    public var hazards: Hazards
    /// Text reports held (weather, notices), not counting aircraft alerts or receiver events.
    public var reportCount: Int

    public var isEmpty: Bool { traffic.tracked == 0 && reportCount == 0 }

    // MARK: Building

    public static func make(from picture: AviationPicture, now: Date) -> AviationBriefing {
        let live = picture.aircraft.values.filter { now.timeIntervalSince($0.lastSeen) <= aircraftTimeout }
        let messages = picture.messages.messages.filter { ![.aircraftAlert, .receiver, .groundStation].contains($0.kind) }
        return AviationBriefing(
            generatedAt: now,
            traffic: traffic(of: live, in: picture),
            emergencies: emergencies(of: live),
            weather: weather(in: picture),
            hazards: hazards(in: picture),
            reportCount: messages.count)
    }

    private static func traffic(of aircraft: [AircraftState], in picture: AviationPicture) -> Traffic {
        var traffic = Traffic()
        traffic.tracked = aircraft.count
        let airborne = aircraft.filter { !$0.onGround }
        traffic.airborne = airborne.count
        traffic.onGround = aircraft.count - airborne.count
        traffic.withPosition = aircraft.filter { $0.coordinate != nil }.count
        for state in aircraft {
            for source in state.sources { traffic.bySource[source.displayName, default: 0] += 1 }
        }
        func best(_ value: (AircraftState) -> Double?) -> Extreme? {
            airborne.compactMap { state in value(state).map { (state, $0) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.displayName < $1.0.displayName }
                .first.map { Extreme(name: $0.0.displayName, value: $0.1) }
        }
        traffic.highest = best { $0.altitudeFeet.map(Double.init) }
        traffic.fastest = best { $0.groundSpeedKnots }
        traffic.farthest = best { picture.rangeNM(of: $0) }
        return traffic
    }

    private static func emergencies(of aircraft: [AircraftState]) -> [Emergency] {
        aircraft.filter(\.isEmergency).sorted { $0.displayName < $1.displayName }.map { state in
            var reasons: [String] = []
            if let declared = state.emergency, declared != ADSBEmergencyState.none { reasons.append(declared.label) }
            if let squawk = state.squawkAlert { reasons.append(squawk.displayName) }
            return Emergency(name: state.displayName, reason: reasons.joined(separator: " / "))
        }
    }

    private static func weather(in picture: AviationPicture) -> Weather {
        var weather = Weather()
        var seen = Set<String>()
        var observations: [(station: String, observation: METARObservation)] = []
        for message in picture.messages.filtered(kinds: [.metar], latestPerStation: true) {
            guard let observation = message.observation else { continue }
            let station = message.station ?? observation.station
            // The feed already keeps the newest report per station; this guards against a tie.
            guard seen.insert(station).inserted else { continue }
            observations.append((station, observation))
        }
        weather.stations = observations.count

        for (_, observation) in observations where observation.flightCategory != .unknown {
            weather.byCategory[observation.flightCategory, default: 0] += 1
        }
        weather.worstCategory = weather.byCategory.keys.max()
        if let worst = weather.worstCategory {
            weather.worstStations = observations.filter { $0.observation.flightCategory == worst }.map(\.station).sorted()
        }
        weather.thunderstormStations = observations.filter { $0.observation.hasThunderstorm }.map(\.station).sorted()
        weather.lowestCeiling = observations
            .compactMap { entry in entry.observation.ceilingFeet.map { Weather.Ceiling(station: entry.station, feet: $0) } }
            .min { $0.feet != $1.feet ? $0.feet < $1.feet : $0.station < $1.station }
        weather.strongestWind = observations
            .compactMap { entry -> Weather.Wind? in
                let gust = entry.observation.windGustKnots
                guard let knots = gust ?? entry.observation.windSpeedKnots, knots > 0 else { return nil }
                return Weather.Wind(station: entry.station, knots: knots, isGust: gust != nil)
            }
            .max { $0.knots != $1.knots ? $0.knots < $1.knots : $0.station > $1.station }
        return weather
    }

    private static func hazards(in picture: AviationPicture) -> Hazards {
        var hazards = Hazards()
        let counts = picture.messages.counts()
        hazards.sigmets = counts[.sigmet] ?? 0
        hazards.airmets = counts[.airmet] ?? 0
        hazards.advisories = counts[.advisory] ?? 0
        hazards.restrictions = counts[.restriction] ?? 0
        hazards.urgent = picture.messages.filtered(minimumSeverity: .warning)
            .filter { ![.aircraftAlert, .receiver, .groundStation].contains($0.kind) }
            .prefix(5).map(\.title)
        return hazards
    }

    // MARK: Words

    public var headline: String {
        if let first = emergencies.first {
            let names = emergencies.map(\.name).joined(separator: ", ")
            return emergencies.count == 1 ? "1 aircraft declaring an emergency: \(first.name)."
                                          : "\(emergencies.count) aircraft declaring an emergency: \(names)."
        }
        var parts: [String] = []
        if traffic.tracked > 0 { parts.append("\(traffic.tracked) aircraft tracked") }
        if weather.stations > 0 {
            if traffic.tracked == 0 { parts.append("\(weather.stations) weather station\(weather.stations == 1 ? "" : "s")") }
            if let worst = weather.worstCategory {
                parts.append(worst == .vfr ? "all stations VFR"
                                           : "worst weather \(worst.rawValue) at \(weather.worstStations.joined(separator: ", "))")
            }
        }
        if hazards.total > 0 { parts.append("\(hazards.total) hazard product\(hazards.total == 1 ? "" : "s") active") }
        if parts.isEmpty { return reportCount > 0 ? "\(reportCount) report\(reportCount == 1 ? "" : "s") held." : "Nothing heard yet." }
        return parts.joined(separator: "; ") + "."
    }

    /// The digest, one fact per line, most urgent first.
    public var lines: [String] {
        if isEmpty { return ["No aircraft or reports heard yet. Start a receiver in Air Map or Air Data."] }
        var lines = emergencies.map { "EMERGENCY: \($0.name) — \($0.reason)" }

        if traffic.tracked == 0 {
            lines.append("No aircraft currently tracked.")
        } else {
            lines.append("\(traffic.tracked) aircraft tracked: \(traffic.airborne) airborne, \(traffic.onGround) on the ground, \(traffic.withPosition) with a position.")
            let sources = traffic.bySource.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
            if !sources.isEmpty { lines.append("Heard on: \(sources.joined(separator: ", ")).") }
            if let highest = traffic.highest { lines.append("Highest: \(highest.name) at \(AviationFormat.altitude(Int(highest.value))).") }
            if let fastest = traffic.fastest { lines.append("Fastest: \(fastest.name) at \(AviationFormat.speed(fastest.value)).") }
            if let farthest = traffic.farthest { lines.append("Farthest: \(farthest.name) at \(AviationFormat.distance(farthest.value)).") }
        }

        if weather.stations > 0 {
            let categories = FlightCategory.allCases.compactMap { category in
                weather.byCategory[category].map { "\($0) \(category.rawValue)" }
            }
            var line = "Weather: \(weather.stations) station\(weather.stations == 1 ? "" : "s")"
            if !categories.isEmpty { line += " (\(categories.joined(separator: ", ")))" }
            line += "."
            if let worst = weather.worstCategory, worst != .vfr {
                line += " Worst: \(weather.worstStations.joined(separator: ", ")) \(worst.rawValue)."
            }
            lines.append(line)
            if !weather.thunderstormStations.isEmpty {
                lines.append("Thunderstorms reported at \(weather.thunderstormStations.joined(separator: ", ")).")
            }
            if let ceiling = weather.lowestCeiling {
                lines.append("Lowest ceiling: \(AviationFormat.grouped(ceiling.feet)) ft at \(ceiling.station).")
            }
            if let wind = weather.strongestWind {
                lines.append("Strongest wind: \(wind.knots) kt\(wind.isGust ? " (gust)" : "") at \(wind.station).")
            }
        }

        let products: [(Int, AviationMessageKind)] = [(hazards.sigmets, .sigmet), (hazards.airmets, .airmet),
                                                      (hazards.advisories, .advisory), (hazards.restrictions, .restriction)]
        let active = products.filter { $0.0 > 0 }.map { "\($0.0) \($0.1.displayName)" }
        if !active.isEmpty { lines.append("Active products: \(active.joined(separator: ", ")).") }
        lines += hazards.urgent.map { "Urgent: \($0)" }
        return lines
    }
}

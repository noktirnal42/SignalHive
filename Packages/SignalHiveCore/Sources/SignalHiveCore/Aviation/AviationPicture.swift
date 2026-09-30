import Foundation

/// One thing a receiver (or the demo) tells the aviation picture.
public enum AviationUpdate: Sendable {
    case aircraft(AircraftReport)
    case radar(RadarBlock, receivedAt: Date)
    case message(AviationMessage)
    case groundStation(GroundStation)
}

public struct AviationStats: Sendable, Equatable {
    /// Aircraft messages applied.
    public var messages = 0
    /// Position fixes applied.
    public var positions = 0
    public var radarBlocks = 0
    public var textReports = 0
    public var farthestNM = 0.0
    public var peakAircraft = 0

    public init() {}
}

/// Everything the map and the text panel show: aircraft with their trails, radar mosaics, ground stations, and the
/// message feed. It is a plain value, so a receiver can build updates off the main thread and the app applies them.
public struct AviationPicture: Sendable, Equatable {
    public internal(set) var aircraft: [UInt32: AircraftState] = [:]
    public internal(set) var radar: [RadarProduct: RadarMosaic] = [:]
    public internal(set) var groundStations: [String: GroundStation] = [:]
    public internal(set) var messages = AviationMessageFeed()
    public internal(set) var stats = AviationStats()
    /// Where the antenna is, when the user has said (used for range and for single-fix position decoding).
    public var receiver: GeoCoordinate?
    /// Increases whenever the set of aircraft or their positions change.
    public internal(set) var revision = 0

    public init(receiver: GeoCoordinate? = nil) {
        self.receiver = receiver
    }

    // MARK: Reading

    /// Aircraft sorted for a list: named flights first, then by name.
    public var sortedAircraft: [AircraftState] {
        aircraft.values.sorted {
            if $0.callsign.isEmpty != $1.callsign.isEmpty { return !$0.callsign.isEmpty }
            return $0.displayName < $1.displayName
        }
    }

    /// Aircraft that have a position, for drawing.
    public var positionedAircraft: [AircraftState] {
        aircraft.values.filter { $0.coordinate != nil }
    }

    public func rangeNM(of state: AircraftState) -> Double? {
        guard let receiver, let coordinate = state.coordinate else { return nil }
        return GeoMath.distanceNM(receiver, coordinate)
    }

    public var emergencyAircraft: [AircraftState] {
        aircraft.values.filter(\.isEmergency).sorted { $0.displayName < $1.displayName }
    }

    // MARK: Updating

    public mutating func apply(_ update: AviationUpdate) {
        switch update {
        case let .aircraft(report): apply(report)
        case let .radar(block, receivedAt): applyRadar(block, at: receivedAt)
        case let .message(message): addMessage(message)
        case let .groundStation(station): apply(station)
        }
    }

    public mutating func apply(_ updates: [AviationUpdate]) {
        for update in updates { apply(update) }
    }

    public mutating func apply(_ report: AircraftReport) {
        stats.messages += 1
        var state = aircraft[report.address] ?? AircraftState(address: report.address, firstSeen: report.time)
        let hadAlert = state.isEmergency
        state.merge(report)

        if let coordinate = report.coordinate, coordinate.isValid {
            state.coordinate = coordinate
            state.lastPositionTime = report.time
            state.history.append(TrackSample(time: report.time, coordinate: coordinate,
                                             altitudeFeet: state.altitudeFeet, onGround: state.onGround))
            stats.positions += 1
            if let receiver {
                stats.farthestNM = max(stats.farthestNM, GeoMath.distanceNM(receiver, coordinate))
            }
            revision += 1
        }
        aircraft[report.address] = state
        stats.peakAircraft = max(stats.peakAircraft, aircraft.count)

        if !hadAlert, state.isEmergency, let alert = AviationMessage.aircraftAlert(state, at: report.time, origin: report.source.displayName) {
            messages.add(alert)
        }
    }

    private mutating func applyRadar(_ block: RadarBlock, at date: Date) {
        var mosaic = radar[block.product] ?? RadarMosaic(product: block.product)
        mosaic.add(block, at: date)
        radar[block.product] = mosaic
        stats.radarBlocks += 1
    }

    private mutating func apply(_ station: GroundStation) {
        if var known = groundStations[station.id] {
            known.lastHeard = max(known.lastHeard, station.lastHeard)
            known.uplinks += 1
            known.slotID = station.slotID
            groundStations[station.id] = known
        } else {
            groundStations[station.id] = station
        }
    }

    public mutating func addMessage(_ message: AviationMessage) {
        if messages.add(message) { stats.textReports += 1 }
    }

    /// Forgets aircraft not heard for `aircraftTimeout` seconds, trims trails to `trailAge`, and drops radar older than
    /// `radarAge`.
    public mutating func expire(now: Date, aircraftTimeout: TimeInterval = 120, trailAge: TimeInterval = 30 * 60,
                                radarAge: TimeInterval = 30 * 60) {
        let before = aircraft.count
        aircraft = aircraft.filter { now.timeIntervalSince($0.value.lastSeen) <= aircraftTimeout }
        for key in Array(aircraft.keys) {
            aircraft[key]?.history.maximumAge = trailAge
            aircraft[key]?.history.trim(now: now)
        }
        for product in Array(radar.keys) {
            radar[product]?.expire(olderThan: radarAge, now: now)
            if radar[product]?.isEmpty == true { radar[product] = nil }
        }
        if aircraft.count != before { revision += 1 }
    }

    public mutating func clear() {
        aircraft.removeAll()
        radar.removeAll()
        groundStations.removeAll()
        messages.clear()
        stats = AviationStats()
        revision += 1
    }
}

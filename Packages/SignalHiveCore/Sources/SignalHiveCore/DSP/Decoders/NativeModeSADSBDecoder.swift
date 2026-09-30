#if canImport(RTLSDRDecoders)
import Foundation
import RTLSDRDecoders

/// SignalHive adapter for SwiftRTLSDR's native Mode S / ADS-B decoder.
///
/// `ModeSDemodulator` works on raw interleaved RTL-SDR u8 I/Q at 2 MS/s. This
/// wrapper keeps that fast path for live dongles while also conforming to
/// `SignalDecoder` for the existing normalized-IQ pipeline.
public final class NativeModeSADSBDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "ADS-B Native"
    public let requiredBandwidth: Double = 4_000_000
    public var timestampProvider: @Sendable () -> Date = { .now }

    private static let nominalFrequencyHz = 1_090_000_000.0
    private let demodulator = ModeSDemodulator()
    private let tracker = AircraftTracker()
    private let bootTime = Date()

    public init() {}

    public func reset() {
        timestampProvider = { .now }
    }

    public func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard !iq.isEmpty, Int(sampleRate.rounded()) == ModeSDemodulator.sampleRate else { return [] }
        var raw = [UInt8]()
        raw.reserveCapacity(iq.count * 2)
        for sample in iq {
            raw.append(Self.u8(fromNormalized: sample.i))
            raw.append(Self.u8(fromNormalized: sample.q))
        }
        return process(rtlRawIQ: raw)
    }

    public func process(rtlRawIQ: [UInt8]) -> [DecodedMessage] {
        demodulator.process(rtlRawIQ).compactMap { frame in
            let timestamp = timestampProvider()
            let elapsed = timestamp.timeIntervalSince(bootTime)
            tracker.update(frame.message, at: elapsed)
            guard let adsb = Self.makeFrame(from: frame.message, timestamp: timestamp) else { return nil }
            return DecodedMessage(
                timestamp: timestamp,
                frequency: Self.nominalFrequencyHz,
                mode: identifier,
                payload: .adsb(adsb)
            )
        }
    }

    public func decodeFrame(hex: String, timestamp: Date = .now) -> ADSBFrame? {
        guard let bytes = Self.bytes(hex: hex), !bytes.isEmpty else { return nil }
        let message = ModeSMessage(bytes: bytes)
        tracker.update(message, at: timestamp.timeIntervalSince(bootTime))
        return Self.makeFrame(from: message, timestamp: timestamp)
    }

    public func allTracks() async -> [AircraftTrack] {
        tracker.aircraft.map(Self.makeTrack(from:))
    }

    private static func makeFrame(from message: ModeSMessage, timestamp: Date) -> ADSBFrame? {
        let payload: ADSBPayload
        let auxiliaryCallsign: String?
        switch message.content {
        case let .altitude(feet):
            guard let feet else { return nil }
            payload = .surveillanceAltitude(altitude: feet, squawk: 0)
            auxiliaryCallsign = nil
        case let .identity(squawk):
            payload = .surveillanceIdentity(squawk: Int(squawk) ?? 0)
            auxiliaryCallsign = nil
        case let .allCall(capability):
            payload = .allCallReply(capability: capability)
            auxiliaryCallsign = nil
        case let .extendedSquitter(squitter):
            let converted = makePayload(from: squitter)
            payload = converted.payload
            auxiliaryCallsign = converted.callsign
        case .other:
            return nil
        }
        return ADSBFrame(
            timestamp: timestamp,
            icaoAddress: Int(message.address),
            downlinkFormat: message.downlinkFormat,
            payload: payload,
            auxiliaryCallsign: auxiliaryCallsign
        )
    }

    private static func makePayload(from squitter: ExtendedSquitter) -> (payload: ADSBPayload, callsign: String?) {
        switch squitter {
        case let .identification(identification):
            return (.identification(callsign: identification.callsign, category: identification.category), identification.callsign)
        case let .airbornePosition(position):
            return (
                .airbornePosition(
                    altitude: position.altitudeFeet ?? 0,
                    lat: Double(position.cpr.latitude) / 131_072.0 * 90.0,
                    lon: Double(position.cpr.longitude) / 131_072.0 * 180.0,
                    oddEven: position.cpr.isOdd ? 1 : 0,
                    cprLat: position.cpr.latitude,
                    cprLon: position.cpr.longitude
                ),
                nil
            )
        case let .velocity(velocity):
            switch velocity.kind {
            case let .ground(speed, track):
                return (.airborneVelocity(speedKts: Int(speed.rounded()), headingDeg: track, vertRateFPM: velocity.verticalRateFPM ?? 0), nil)
            case let .air(heading, airspeed, _):
                return (.airborneVelocity(speedKts: airspeed ?? 0, headingDeg: heading ?? 0, vertRateFPM: velocity.verticalRateFPM ?? 0), nil)
            case nil:
                return (.unknown(typeCode: 19), nil)
            }
        case let .emergency(state, squawk):
            return (.aircraftStatus(squawk: Int(squawk) ?? 0, emergencyState: ADSBEmergencyState(rawValue: state) ?? .reserved), nil)
        case let .other(typeCode):
            return (.unknown(typeCode: typeCode), nil)
        }
    }

    private static func makeTrack(from aircraft: AircraftTracker.Aircraft) -> AircraftTrack {
        var track = AircraftTrack(id: Int(aircraft.address))
        // AircraftTrack stores "not yet received" as "" / 0 (its optional-typed aliases map 0 back to nil).
        track.callsign = aircraft.callsign ?? ""
        track.squawk = aircraft.squawk ?? ""
        track.altitude = aircraft.altitudeFeet ?? 0
        track.groundSpeed = aircraft.groundSpeedKnots.flatMap { $0.isFinite ? Int($0.rounded()) : nil } ?? 0
        track.heading = aircraft.trackDegrees ?? 0
        track.vertRate = aircraft.verticalRateFPM ?? 0
        if let latitude = aircraft.latitude, let longitude = aircraft.longitude {
            track.positions.append(AircraftPosition(
                timestamp: Date(timeIntervalSinceReferenceDate: aircraft.lastPosition ?? aircraft.lastSeen),
                coordinate: .init(latitude: latitude, longitude: longitude),
                altitude: aircraft.altitudeFeet ?? 0
            ))
        }
        return track
    }

    private static func bytes(hex: String) -> [UInt8]? {
        let stripped = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        var index = stripped.startIndex
        while index < stripped.endIndex {
            let next = stripped.index(index, offsetBy: 2)
            guard let byte = UInt8(stripped[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func u8(fromNormalized value: Float) -> UInt8 {
        let scaled = (value * 127.5 + 127.5).rounded()
        return UInt8(min(255, max(0, Int(scaled))))
    }
}
#endif

import Foundation
import CoreLocation

/// First-pass 978 MHz UAT decoder for clean binary FSK IQ captures.
///
/// The demodulator recovers one hard decision per UAT symbol from phase
/// transitions, then scans for a compact UAT application frame used by the
/// replay/live pipeline until a full dump978-compatible bridge is available.
public final class UATDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "UAT"
    public let requiredBandwidth: Double = 1_300_000
    public var timestampProvider: @Sendable () -> Date = { .now }

    private static let nominalFrequencyHz = 978_000_000.0
    private static let symbolRate = 1_041_667.0
    private static let minimumSampleRate = 1_000_000.0
    private static let sync: [Int] = [
        1, 0, 1, 0, 0, 1, 1, 1,
        1, 0, 0, 1, 0, 1, 0, 1,
        0, 1, 1, 0, 1, 0, 0, 1,
        1, 1, 0, 0, 0, 1, 0, 1
    ]
    private static let maxPayloadBytes = 220
    private static let maxCarryBits = 4096
    private static let maxRecentFrames = 500
    private static let maxWeatherProducts = 200
    private static let aircraftFlagOnGround: UInt8 = 1 << 0
    private static let aircraftFlagHasSquawk: UInt8 = 1 << 1
    private static let aircraftFlagHasEmergency: UInt8 = 1 << 2
    private static let aircraftFlagAlert: UInt8 = 1 << 3
    private static let aircraftFlagSPI: UInt8 = 1 << 4

    private var bitCarry: [Int] = []
    private var lastSample: ComplexFloat?
    private var lastSampleRate: Double?
    private var tracks: [Int: AircraftTrack] = [:]
    private var recentFrames: [UATFrame] = []
    private var weatherProducts: [UATWeatherProduct] = []

    public init() {}

    public func reset() {
        bitCarry.removeAll(keepingCapacity: true)
        lastSample = nil
        lastSampleRate = nil
        tracks.removeAll(keepingCapacity: true)
        recentFrames.removeAll(keepingCapacity: true)
        weatherProducts.removeAll(keepingCapacity: true)
        timestampProvider = { .now }
    }

    public func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard sampleRate >= Self.minimumSampleRate, !iq.isEmpty else { return [] }

        if lastSampleRate != sampleRate {
            bitCarry.removeAll()
            lastSample = nil
            lastSampleRate = sampleRate
        }

        let timestamp = timestampProvider()
        let bits = hardDecisionBits(from: iq, sampleRate: sampleRate)
        guard !bits.isEmpty else { return [] }

        let frames = extractFrames(from: bits, timestamp: timestamp)
        return frames.map { frame in
            DecodedMessage(
                timestamp: frame.timestamp,
                frequency: frame.frequency,
                mode: identifier,
                payload: .uat(frame)
            )
        }
    }

    public func allAircraftTracks() async -> [AircraftTrack] {
        tracks.values.sorted { $0.id < $1.id }
    }

    public func allFrames() async -> [UATFrame] {
        recentFrames
    }

    public func allWeatherProducts() async -> [UATWeatherProduct] {
        weatherProducts
    }

    private func hardDecisionBits(from iq: [ComplexFloat], sampleRate: Double) -> [Int] {
        let samplesPerSymbol = max(1, Int(round(sampleRate / Self.symbolRate)))
        var discriminator: [Float] = []
        discriminator.reserveCapacity(iq.count)

        var previous = lastSample ?? iq[0]
        for sample in iq {
            let cross = previous.i * sample.q - previous.q * sample.i
            let dot = previous.i * sample.i + previous.q * sample.q
            discriminator.append(atan2f(cross, dot))
            previous = sample
        }
        lastSample = previous

        guard discriminator.count >= samplesPerSymbol else { return [] }

        var bits: [Int] = []
        var cursor = samplesPerSymbol / 2
        while cursor < discriminator.count {
            bits.append(discriminator[cursor] >= 0 ? 1 : 0)
            cursor += samplesPerSymbol
        }
        return bits
    }

    private func extractFrames(from newBits: [Int], timestamp: Date) -> [UATFrame] {
        let bits = bitCarry + newBits
        var frames: [UATFrame] = []
        var cursor = 0
        var consumedThrough = 0

        while cursor + Self.sync.count + 8 <= bits.count {
            guard matchesSync(in: bits, at: cursor) else {
                cursor += 1
                continue
            }

            let lengthStart = cursor + Self.sync.count
            let payloadLength = Int(byte(from: bits, at: lengthStart))
            guard payloadLength > 0, payloadLength <= Self.maxPayloadBytes else {
                cursor += 1
                consumedThrough = max(consumedThrough, cursor)
                continue
            }

            let totalBits = Self.sync.count + 8 + payloadLength * 8 + 16
            guard cursor + totalBits <= bits.count else { break }

            let payloadStart = lengthStart + 8
            let payload = bytes(from: bits, start: payloadStart, count: payloadLength)
            let expectedCRC = UInt16(byte(from: bits, at: payloadStart + payloadLength * 8)) << 8 |
                UInt16(byte(from: bits, at: payloadStart + payloadLength * 8 + 8))

            if crc16(payload) == expectedCRC, let frame = decode(payload: payload, timestamp: timestamp) {
                frames.append(frame)
                remember(frame)
                cursor += totalBits
                consumedThrough = cursor
            } else {
                cursor += 1
                consumedThrough = max(consumedThrough, cursor)
            }
        }

        let remaining = Array(bits.dropFirst(consumedThrough))
        bitCarry = remaining.count > Self.maxCarryBits ? Array(remaining.suffix(Self.maxCarryBits)) : remaining
        return frames
    }

    private func matchesSync(in bits: [Int], at index: Int) -> Bool {
        guard index + Self.sync.count <= bits.count else { return false }
        for offset in 0..<Self.sync.count where bits[index + offset] != Self.sync[offset] {
            return false
        }
        return true
    }

    private func byte(from bits: [Int], at start: Int) -> UInt8 {
        var value: UInt8 = 0
        for bit in 0..<8 {
            value = (value << 1) | UInt8(bits[start + bit] & 1)
        }
        return value
    }

    private func bytes(from bits: [Int], start: Int, count: Int) -> [UInt8] {
        (0..<count).map { byte(from: bits, at: start + $0 * 8) }
    }

    private func decode(payload: [UInt8], timestamp: Date) -> UATFrame? {
        guard let type = payload.first else { return nil }

        switch type {
        case 0x01:
            return decodeAircraft(payload: payload, timestamp: timestamp)
        case 0x02:
            return decodeWeather(payload: payload, timestamp: timestamp)
        default:
            return UATFrame(
                timestamp: timestamp,
                frequency: Self.nominalFrequencyHz,
                payload: .unknown(messageType: type, rawPayload: payload)
            )
        }
    }

    private func decodeAircraft(payload: [UInt8], timestamp: Date) -> UATFrame? {
        guard payload.count >= 28 else { return nil }

        let address = (Int(payload[1]) << 16) | (Int(payload[2]) << 8) | Int(payload[3])
        let latitude = Double(readInt32(payload, at: 4)) / 10_000_000.0
        let longitude = Double(readInt32(payload, at: 8)) / 10_000_000.0
        let altitude = Int(readInt16(payload, at: 12))
        let speed = Int(readUInt16(payload, at: 14))
        let heading = Double(readUInt16(payload, at: 16)) / 100.0
        let verticalRate = Int(readInt16(payload, at: 18))
        let callsign = String(decoding: payload[20..<28].prefix(8), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let flags = payload.count >= 29 ? payload[28] : 0
        let hasExtendedState = payload.count >= 29
        let squawk = payload.count >= 31 && (flags & Self.aircraftFlagHasSquawk) != 0
            ? Int(readUInt16(payload, at: 29))
            : nil
        let emergencyState = payload.count >= 32 && (flags & Self.aircraftFlagHasEmergency) != 0
            ? (ADSBEmergencyState(rawValue: Int(payload[31])) ?? .reserved)
            : nil

        let report = UATAircraftReport(
            address: address,
            callsign: callsign,
            latitude: latitude,
            longitude: longitude,
            altitudeFt: altitude,
            groundSpeedKts: speed,
            headingDeg: heading,
            verticalRateFpm: verticalRate,
            squawk: squawk,
            emergencyState: emergencyState,
            isOnGround: hasExtendedState ? (flags & Self.aircraftFlagOnGround) != 0 : nil,
            surveillanceAlertActive: hasExtendedState ? (flags & Self.aircraftFlagAlert) != 0 : nil,
            specialPositionIdentificationActive: hasExtendedState ? (flags & Self.aircraftFlagSPI) != 0 : nil
        )
        let frame = UATFrame(timestamp: timestamp, frequency: Self.nominalFrequencyHz, payload: .aircraft(report))
        apply(report: report, timestamp: timestamp)
        return frame
    }

    private func decodeWeather(payload: [UInt8], timestamp: Date) -> UATFrame? {
        guard payload.count >= 16 else { return nil }

        let productID = Int(readUInt16(payload, at: 1))
        let latitudeRaw = readInt32(payload, at: 3)
        let longitudeRaw = readInt32(payload, at: 7)
        let latitude = latitudeRaw == Int32.min ? nil : Double(latitudeRaw) / 10_000_000.0
        let longitude = longitudeRaw == Int32.min ? nil : Double(longitudeRaw) / 10_000_000.0
        let rawStation = String(decoding: payload[11..<15], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(decoding: payload[15...], as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)
        let inferredKind = UATWeatherKind(product: UATWeatherProduct(
            timestamp: timestamp,
            productID: productID,
            station: rawStation,
            latitude: latitude,
            longitude: longitude,
            text: text
        ))
        let station = rawStation.isEmpty ? (UATWeatherProduct.inferredStation(fromText: text, kind: inferredKind) ?? "") : rawStation

        let product = UATWeatherProduct(
            timestamp: timestamp,
            productID: productID,
            station: station,
            latitude: latitude,
            longitude: longitude,
            text: text
        )
        let frame = UATFrame(timestamp: timestamp, frequency: Self.nominalFrequencyHz, payload: .weather(product))
        remember(product)
        return frame
    }

    private func apply(report: UATAircraftReport, timestamp: Date) {
        var track = tracks[report.address] ?? AircraftTrack(id: report.address)
        if !report.callsign.isEmpty {
            track.callsign = report.callsign
        }
        track.altitude = report.altitudeFt
        track.groundSpeed = report.groundSpeedKts
        track.heading = report.headingDeg
        track.vertRate = report.verticalRateFpm
        if let squawk = report.squawk, squawk > 0 {
            track.squawk = String(format: "%04d", squawk)
        }
        if let emergencyState = report.emergencyState {
            track.emergencyState = emergencyState == .none ? nil : emergencyState
        }
        if let isOnGround = report.isOnGround {
            track.isOnGround = isOnGround
        }
        if let alert = report.surveillanceAlertActive {
            track.surveillanceAlertActive = alert
        }
        if let spi = report.specialPositionIdentificationActive {
            track.specialPositionIdentificationActive = spi
        }
        track.lastUpdate = timestamp
        track.positions.append(AircraftPosition(
            timestamp: timestamp,
            coordinate: CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude),
            altitude: report.altitudeFt
        ))
        if track.positions.count > 100 { track.positions.removeFirst() }
        tracks[report.address] = track
    }

    private func remember(_ frame: UATFrame) {
        recentFrames.append(frame)
        if recentFrames.count > Self.maxRecentFrames {
            recentFrames.removeFirst(recentFrames.count - Self.maxRecentFrames)
        }
    }

    private func remember(_ product: UATWeatherProduct) {
        weatherProducts.append(product)
        if weatherProducts.count > Self.maxWeatherProducts {
            weatherProducts.removeFirst(weatherProducts.count - Self.maxWeatherProducts)
        }
    }

    private func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    private func readInt16(_ bytes: [UInt8], at index: Int) -> Int16 {
        Int16(bitPattern: readUInt16(bytes, at: index))
    }

    private func readInt32(_ bytes: [UInt8], at index: Int) -> Int32 {
        let value = UInt32(bytes[index]) << 24 |
            UInt32(bytes[index + 1]) << 16 |
            UInt32(bytes[index + 2]) << 8 |
            UInt32(bytes[index + 3])
        return Int32(bitPattern: value)
    }

    private func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }
}

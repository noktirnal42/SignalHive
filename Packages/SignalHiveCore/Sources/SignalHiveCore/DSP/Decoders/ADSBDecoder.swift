import Foundation
import CoreLocation

// MARK: - ADS-B Frame Types

public struct ADSBFrame: Sendable, Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let icaoAddress: Int      // 24-bit ICAO aircraft address
    public let downlinkFormat: Int   // DF field
    public let payload: ADSBPayload
    public let auxiliaryCallsign: String?
    public let flightStatus: ADSBFlightStatus?

    public init(
        timestamp: Date,
        icaoAddress: Int,
        downlinkFormat: Int,
        payload: ADSBPayload,
        auxiliaryCallsign: String? = nil,
        flightStatus: ADSBFlightStatus? = nil
    ) {
        self.timestamp = timestamp
        self.icaoAddress = icaoAddress
        self.downlinkFormat = downlinkFormat
        self.payload = payload
        self.auxiliaryCallsign = auxiliaryCallsign
        self.flightStatus = flightStatus
    }
}

public enum ADSBPayload: Sendable {
    case allCallReply(capability: Int)
    case airAirSurveillance(altitude: Int, capability: Int)
    case identification(callsign: String, category: Int)
    case airbornePosition(altitude: Int, lat: Double, lon: Double, oddEven: Int, cprLat: Int, cprLon: Int)
    case airborneVelocity(speedKts: Int, headingDeg: Double, vertRateFPM: Int)
    case surveillanceAltitude(altitude: Int, squawk: Int)
    case surveillanceIdentity(squawk: Int)
    case aircraftStatus(squawk: Int, emergencyState: ADSBEmergencyState)
    case groundPosition(lat: Double, lon: Double, groundSpeed: Int, trackDeg: Double)
    case unknown(typeCode: Int)
}

public enum ADSBEmergencyState: Int, Sendable, Codable, CaseIterable {
    case none = 0
    case general = 1
    case lifeguardMedical = 2
    case minimumFuel = 3
    case noCommunications = 4
    case unlawfulInterference = 5
    case downedAircraft = 6
    case reserved = 7

    public var label: String {
        switch self {
        case .none:
            return "No Emergency"
        case .general:
            return "General Emergency"
        case .lifeguardMedical:
            return "Lifeguard / Medical"
        case .minimumFuel:
            return "Minimum Fuel"
        case .noCommunications:
            return "No Communications"
        case .unlawfulInterference:
            return "Unlawful Interference"
        case .downedAircraft:
            return "Downed Aircraft"
        case .reserved:
            return "Reserved"
        }
    }
}

public enum ADSBFlightStatus: Int, Sendable, Codable, CaseIterable {
    case airborne = 0
    case onGround = 1
    case airborneAlert = 2
    case onGroundAlert = 3
    case alertSPI = 4
    case spi = 5
    case reserved = 6
    case notAssigned = 7

    public var isOnGround: Bool? {
        switch self {
        case .airborne, .airborneAlert:
            return false
        case .onGround, .onGroundAlert:
            return true
        case .alertSPI, .spi, .reserved, .notAssigned:
            return nil
        }
    }

    public var hasAlert: Bool {
        switch self {
        case .airborneAlert, .onGroundAlert, .alertSPI:
            return true
        case .airborne, .onGround, .spi, .reserved, .notAssigned:
            return false
        }
    }

    public var hasSPI: Bool {
        switch self {
        case .alertSPI, .spi:
            return true
        case .airborne, .onGround, .airborneAlert, .onGroundAlert, .reserved, .notAssigned:
            return false
        }
    }
}

// MARK: - Aircraft Track

public struct AircraftTrack: Identifiable, Hashable, Sendable {
    public let id: Int  // ICAO address
    public var callsign: String = ""
    public var squawk: String = ""
    public var emergencyState: ADSBEmergencyState? = nil
    public var category: Int = 0
    public var altitude: Int = 0      // feet
    public var groundSpeed: Int = 0   // knots
    public var heading: Double = 0
    public var vertRate: Int = 0      // ft/min
    public var positions: [AircraftPosition] = []
    public var lastUpdate: Date = .now
    public var isOnGround: Bool = false
    public var surveillanceAlertActive: Bool = false
    public var specialPositionIdentificationActive: Bool = false

    public var latestPosition: AircraftPosition? { positions.last }
    public var coordinate: CLLocationCoordinate2D? { latestPosition?.coordinate }

    // Compatibility aliases used by the UI layer and future storage pipeline.
    public var icaoAddress: Int { id }
    public var altitudeFt: Int? { altitude == 0 ? nil : altitude }
    public var groundSpeedKts: Int? { groundSpeed == 0 ? nil : groundSpeed }
    public var headingDeg: Double? { heading == 0 ? nil : heading }
    public var vertRateFpm: Int? { vertRate == 0 ? nil : vertRate }
    public var lastSeen: Date { lastUpdate }
    public var lastLat: Double? { latestPosition?.coordinate.latitude }
    public var lastLon: Double? { latestPosition?.coordinate.longitude }

    public static func == (lhs: AircraftTrack, rhs: AircraftTrack) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct AircraftPosition: Sendable {
    public var timestamp: Date
    public var coordinate: CLLocationCoordinate2D
    public var altitude: Int
}

// MARK: - ADS-B Decoder

/// Decodes Mode S messages at 1090 MHz.
public final class ADSBDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "ADS-B"
    public let requiredBandwidth: Double = 4_000_000  // 1090 MHz ±2 MHz
    public var timestampProvider: @Sendable () -> Date = { .now }

    private static let nominalFrequencyHz = 1_090_000_000.0
    private static let minimumSampleRate = 2_000_000.0
    private static let preambleDurationUs = 8.0
    private static let bitDurationUs = 1.0
    private static let shortMessageBitCount = 56
    private static let longMessageBitCount = 112

    private var aircraftTracks: [Int: AircraftTrack] = [:]
    // CPR decode state (needs paired odd/even messages)
    private var cprFrames: [Int: [Int: ADSBFrame]] = [:]  // icao → [0|1 → frame]
    private var magnitudeCarry: [Float] = []
    private var samplesSeen: Int64 = 0
    private var searchedThroughAbsoluteStart: Int64 = -1
    private var lastSampleRate: Double?

    public init() {}

    public func reset() {
        aircraftTracks.removeAll(keepingCapacity: true)
        cprFrames.removeAll(keepingCapacity: true)
        magnitudeCarry.removeAll(keepingCapacity: true)
        samplesSeen = 0
        searchedThroughAbsoluteStart = -1
        lastSampleRate = nil
        timestampProvider = { .now }
    }

    public func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard sampleRate >= Self.minimumSampleRate, !iq.isEmpty else { return [] }

        if lastSampleRate != sampleRate {
            resetSampleBuffer(sampleRate: sampleRate)
        }

        let shortFrameSamples = samplesFor(us: Self.preambleDurationUs + Double(Self.shortMessageBitCount) * Self.bitDurationUs,
                                           sampleRate: sampleRate)
        let maxFrameSamples = samplesFor(us: Self.preambleDurationUs + Double(Self.longMessageBitCount) * Self.bitDurationUs,
                                         sampleRate: sampleRate)
        guard shortFrameSamples > 0, maxFrameSamples > 0 else { return [] }

        let newMagnitudes = iq.map(\.magnitude)
        let carryCount = magnitudeCarry.count
        let combined = magnitudeCarry + newMagnitudes
        let combinedAbsoluteStart = samplesSeen - Int64(carryCount)
        let currentMaxStart = combined.count - shortFrameSamples

        samplesSeen += Int64(iq.count)
        defer {
            let keep = min(maxFrameSamples - 1, combined.count)
            magnitudeCarry = Array(combined.suffix(keep))
        }

        guard currentMaxStart >= 0 else { return [] }

        let firstUnsearched = max(combinedAbsoluteStart, searchedThroughAbsoluteStart + 1)
        let lastSearchStart = combinedAbsoluteStart + Int64(currentMaxStart)
        let settledSearchStart = combinedAbsoluteStart + Int64(combined.count - maxFrameSamples)
        guard firstUnsearched <= lastSearchStart else { return [] }

        var messages: [DecodedMessage] = []
        var relativeStart = Int(firstUnsearched - combinedAbsoluteStart)
        while relativeStart <= currentMaxStart {
            let timestamp = timestampProvider()
            if isPreamble(at: relativeStart, in: combined, sampleRate: sampleRate),
               let (bytes, bitCount) = decodeMessageBytes(at: relativeStart, in: combined, sampleRate: sampleRate),
               let frame = decodeFrame(hex: bytesToHex(bytes), timestamp: timestamp) {
                messages.append(DecodedMessage(
                    timestamp: frame.timestamp,
                    frequency: Self.nominalFrequencyHz,
                    mode: identifier,
                    payload: .adsb(frame)
                ))

                let consumedSamples = samplesFor(
                    us: Self.preambleDurationUs + Double(bitCount) * Self.bitDurationUs,
                    sampleRate: sampleRate
                )
                relativeStart += max(1, consumedSamples)
            } else {
                relativeStart += 1
            }
        }

        searchedThroughAbsoluteStart = min(lastSearchStart, settledSearchStart)
        return messages
    }

    // MARK: - Mode S frame decoder (raw 112-bit hex string → ADSBFrame)

    public func decodeFrame(hex: String, timestamp: Date = .now) -> ADSBFrame? {
        guard hex.count >= 14 else { return nil }

        guard let bytes = hexToBytes(hex) else { return nil }
        guard bytes.count >= 7 else { return nil }

        let df = Int(bytes[0]) >> 3      // Downlink Format (5 bits)
        let expectedCRC = crc24(bytes: Array(bytes.dropLast(3)))
        let transmittedParity = transmittedParity(bytes: bytes)
        let icao: Int

        if df == 17 || df == 18 {
            guard expectedCRC == transmittedParity else { return nil }
            // Extended squitter: ICAO in bytes 1-3
            icao = (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        } else if df == 11 {
            guard expectedCRC == transmittedParity else { return nil }
            icao = (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        } else if df == 0 || df == 4 || df == 5 || df == 16 || df == 20 || df == 21 {
            icao = Int(expectedCRC ^ transmittedParity)
            guard (1...0xFF_FFFF).contains(icao) else { return nil }
        } else {
            return nil  // Only decode DF0/4/5/11/16/17/18 and first-pass DF20/DF21 for now
        }

        let payload = decodePayload(bytes: bytes, df: df)
        let frame = ADSBFrame(
            timestamp: timestamp,
            icaoAddress: icao,
            downlinkFormat: df,
            payload: payload,
            auxiliaryCallsign: decodeCommBAircraftIdentification(bytes: bytes, df: df),
            flightStatus: decodeFlightStatus(bytes: bytes, df: df)
        )
        apply(frame: frame)
        return frame
    }

    public func allTracks() async -> [AircraftTrack] {
        aircraftTracks.values.sorted { $0.id < $1.id }
    }

    public func apply(frame: ADSBFrame) {
        var track = aircraftTracks[frame.icaoAddress] ?? AircraftTrack(id: frame.icaoAddress)
        track.lastUpdate = frame.timestamp

        switch frame.payload {
        case .allCallReply:
            break
        case .airAirSurveillance(let altitude, _):
            track.altitude = altitude
            track.isOnGround = false
        case .identification(let callsign, let category):
            track.callsign = callsign
            track.category = category
        case .airbornePosition(let altitude, _, _, let oddEven, _, _):
            track.altitude = altitude
            track.isOnGround = false
            cprFrames[frame.icaoAddress, default: [:]][oddEven] = frame
            if let coordinate = decodeGlobalAirborneCPR(for: frame.icaoAddress, newestOddEven: oddEven) {
                track.positions.append(AircraftPosition(timestamp: frame.timestamp,
                                                        coordinate: coordinate,
                                                        altitude: altitude))
                if track.positions.count > 100 { track.positions.removeFirst() }
            }
        case .airborneVelocity(let speedKts, let headingDeg, let vertRateFPM):
            track.groundSpeed = speedKts
            track.heading = headingDeg
            track.vertRate = vertRateFPM
            track.isOnGround = false
        case .surveillanceAltitude(let altitude, let squawk):
            track.altitude = altitude
            if squawk > 0 {
                track.squawk = String(format: "%04d", squawk)
            }
            if let auxiliaryCallsign = frame.auxiliaryCallsign, !auxiliaryCallsign.isEmpty {
                track.callsign = auxiliaryCallsign
            }
            applyFlightStatus(frame.flightStatus, to: &track)
        case .surveillanceIdentity(let squawk):
            track.squawk = String(format: "%04d", squawk)
            if let auxiliaryCallsign = frame.auxiliaryCallsign, !auxiliaryCallsign.isEmpty {
                track.callsign = auxiliaryCallsign
            }
            applyFlightStatus(frame.flightStatus, to: &track)
        case .aircraftStatus(let squawk, let emergencyState):
            track.squawk = String(format: "%04d", squawk)
            track.emergencyState = emergencyState == .none ? nil : emergencyState
        case .groundPosition(let lat, let lon, let groundSpeed, let trackDeg):
            track.groundSpeed = groundSpeed
            track.heading = trackDeg
            track.positions.append(AircraftPosition(timestamp: frame.timestamp,
                                                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                                    altitude: track.altitude))
            if track.positions.count > 100 { track.positions.removeFirst() }
            track.isOnGround = true
        case .unknown:
            break
        }

        aircraftTracks[frame.icaoAddress] = track
    }

    private func applyFlightStatus(_ status: ADSBFlightStatus?, to track: inout AircraftTrack) {
        guard let status else { return }
        if let isOnGround = status.isOnGround {
            track.isOnGround = isOnGround
        }
        track.surveillanceAlertActive = status.hasAlert
        track.specialPositionIdentificationActive = status.hasSPI
    }

    private func decodePayload(bytes: [UInt8], df: Int) -> ADSBPayload {
        switch df {
        case 0, 16:
            return decodeAirAirSurveillance(bytes: bytes)
        case 11:
            return decodeAllCallReply(bytes: bytes)
        case 17, 18:
            guard bytes.count >= 14 else { return .unknown(typeCode: 0) }

            let me = Array(bytes[4..<11])  // 56-bit ME field
            let typeCode = Int(me[0]) >> 3

            switch typeCode {
            case 1...4:
                return decodeIdentification(me: me, typeCode: typeCode)
            case 5...8:
                return decodeGroundPosition(me: me)
            case 9...18, 20...22:
                return decodeAirbornePosition(me: me)
            case 19:
                return decodeAirborneVelocity(me: me)
            case 28:
                return decodeAircraftStatus(me: me)
            default:
                return .unknown(typeCode: typeCode)
            }
        case 4, 20:
            return decodeSurveillanceAltitude(bytes: bytes)
        case 5, 21:
            return decodeSurveillanceIdentity(bytes: bytes)
        default:
            return .unknown(typeCode: 0)
        }
    }

    private func decodeAllCallReply(bytes: [UInt8]) -> ADSBPayload {
        guard bytes.count >= 1 else { return .unknown(typeCode: 0) }
        let capability = Int(bytes[0]) & 0x07
        return .allCallReply(capability: capability)
    }

    private func decodeAirAirSurveillance(bytes: [UInt8]) -> ADSBPayload {
        guard bytes.count >= 4 else { return .unknown(typeCode: 0) }

        let capability = Int(bytes[0]) & 0x07
        let altitudeCode = ((Int(bytes[2]) & 0x1F) << 8) | Int(bytes[3])
        guard let altitude = decodeModeSAltitudeCode(altitudeCode) else {
            return .unknown(typeCode: 0)
        }

        return .airAirSurveillance(altitude: altitude, capability: capability)
    }

    private func decodeIdentification(me: [UInt8], typeCode: Int) -> ADSBPayload {
        let category = Int(me[0]) & 0x07
        let callsign = decodeCallsign(from: Array(me[1...6]))
        return .identification(callsign: callsign, category: category)
    }

    private func decodeAirbornePosition(me: [UInt8]) -> ADSBPayload {
        let altCode = (Int(me[1]) << 4) | (Int(me[2]) >> 4)
        var altitude = 0
        if altCode & 0x10 != 0 {
            // 25 ft increments
            altitude = ((altCode & 0xFE0) >> 1 | (altCode & 0xF)) * 25 - 1000
        } else {
            altitude = altCode * 100 - 1000
        }

        let oddEven = (Int(me[2]) >> 2) & 1
        let lat_cpr = (Int(me[2] & 0x03) << 15) | (Int(me[3]) << 7) | (Int(me[4]) >> 1)
        let lon_cpr = (Int(me[4] & 0x01) << 16) | (Int(me[5]) << 8) | Int(me[6])

        let latRaw = Double(lat_cpr) / 131072.0
        let lonRaw = Double(lon_cpr) / 131072.0
        return .airbornePosition(
            altitude: altitude,
            lat: latRaw * 90,
            lon: lonRaw * 180,
            oddEven: oddEven,
            cprLat: lat_cpr,
            cprLon: lon_cpr
        )
    }

    private func decodeAirborneVelocity(me: [UInt8]) -> ADSBPayload {
        let subtype = Int(me[0]) & 0x07
        var speed = 0
        var heading = 0.0
        var vertRate = 0

        if subtype == 1 || subtype == 2 {
            let ewDir = (Int(me[1]) >> 2) & 1
            let ewRaw = ((Int(me[1]) & 0x03) << 8) | Int(me[2])
            let nsDir = (Int(me[3]) >> 7)
            let nsRaw = ((Int(me[3]) & 0x7F) << 3) | (Int(me[4]) >> 5)
            let scale = subtype == 2 ? 4.0 : 1.0

            let ewVelocity = max(ewRaw - 1, 0)
            let nsVelocity = max(nsRaw - 1, 0)
            let ew = Double(ewVelocity) * scale * (ewDir == 1 ? -1 : 1)
            let ns = Double(nsVelocity) * scale * (nsDir == 1 ? -1 : 1)

            if ewVelocity > 0 || nsVelocity > 0 {
                speed = Int(sqrt(ew * ew + ns * ns))
                heading = atan2(ew, ns) * 180.0 / .pi
                if heading < 0 { heading += 360 }
            }
        } else if subtype == 3 || subtype == 4 {
            let scale = subtype == 4 ? 4.0 : 1.0
            let headingValid = ((me[1] >> 2) & 0x01) == 1
            let headingRaw = extractBits(from: me, startBit: 14, bitCount: 10)
            let airspeedRaw = extractBits(from: me, startBit: 25, bitCount: 10)

            if headingValid {
                heading = Double(headingRaw) * 360.0 / 1024.0
                if heading >= 360 { heading -= 360 }
            }
            if airspeedRaw > 0 {
                speed = Int((Double(airspeedRaw) - 1.0) * scale)
            }
        }

        let vrSign = (Int(me[4]) >> 3) & 1
        let vrRaw = ((Int(me[4]) & 0x07) << 6) | (Int(me[5]) >> 2)
        if vrRaw > 0 {
            vertRate = (vrRaw - 1) * 64
            if vrSign == 1 { vertRate = -vertRate }
        }

        return .airborneVelocity(speedKts: speed, headingDeg: heading, vertRateFPM: vertRate)
    }

    private func decodeGroundPosition(me: [UInt8]) -> ADSBPayload {
        let speed = (Int(me[0] & 0x07) << 7) | (Int(me[1]) >> 1)
        let trackValid = Int(me[1]) & 1
        let track = trackValid == 1 ? Double((Int(me[2]) << 4) | (Int(me[3]) >> 4)) * 360.0 / 128.0 : 0.0
        let lat_cpr = (Int(me[3] & 0x0F) << 13) | (Int(me[4]) << 5) | (Int(me[5]) >> 3)
        let lon_cpr = (Int(me[5] & 0x07) << 14) | (Int(me[6]) << 6)
        return .groundPosition(
            lat: Double(lat_cpr) / 131072.0 * 90,
            lon: Double(lon_cpr) / 131072.0 * 180,
            groundSpeed: speed,
            trackDeg: track
        )
    }

    private func decodeAircraftStatus(me: [UInt8]) -> ADSBPayload {
        let subtype = Int(me[0]) & 0x07
        guard subtype == 1 else { return .unknown(typeCode: 28) }

        let emergencyRaw = extractBits(from: me, startBit: 8, bitCount: 3)
        let identityCode = extractBits(from: me, startBit: 11, bitCount: 13)
        let emergencyState = ADSBEmergencyState(rawValue: emergencyRaw) ?? .reserved
        let squawk = decodeIdentityCode(identityCode)
        return .aircraftStatus(squawk: squawk, emergencyState: emergencyState)
    }

    private func decodeSurveillanceAltitude(bytes: [UInt8]) -> ADSBPayload {
        guard bytes.count >= 4 else { return .unknown(typeCode: 0) }

        let altitudeCode = ((Int(bytes[2]) & 0x1F) << 8) | Int(bytes[3])
        guard let altitude = decodeModeSAltitudeCode(altitudeCode) else {
            return .unknown(typeCode: 0)
        }

        return .surveillanceAltitude(altitude: altitude, squawk: 0)
    }

    private func decodeSurveillanceIdentity(bytes: [UInt8]) -> ADSBPayload {
        guard bytes.count >= 4 else { return .unknown(typeCode: 0) }

        let identityCode = ((Int(bytes[2]) & 0x1F) << 8) | Int(bytes[3])
        let squawk = decodeIdentityCode(identityCode)
        guard squawk > 0 else { return .unknown(typeCode: 0) }
        return .surveillanceIdentity(squawk: squawk)
    }

    private func decodeCommBAircraftIdentification(bytes: [UInt8], df: Int) -> String? {
        guard df == 20 || df == 21 else { return nil }
        guard bytes.count >= 11 else { return nil }

        let message = Array(bytes[4..<11])
        guard message.first == 0x20 else { return nil }

        let callsign = decodeCallsign(from: Array(message.dropFirst()))
        return callsign.isEmpty ? nil : callsign
    }

    private func decodeFlightStatus(bytes: [UInt8], df: Int) -> ADSBFlightStatus? {
        guard df == 4 || df == 5 || df == 20 || df == 21 else { return nil }
        guard let byte0 = bytes.first else { return nil }
        return ADSBFlightStatus(rawValue: Int(byte0 & 0x07))
    }

    private func decodeCallsign(from packedBytes: [UInt8]) -> String {
        guard packedBytes.count >= 6 else { return "" }

        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ     0123456789       "
        let combined = (Int(packedBytes[0]) << 40) | (Int(packedBytes[1]) << 32) |
            (Int(packedBytes[2]) << 24) | (Int(packedBytes[3]) << 16) |
            (Int(packedBytes[4]) << 8) | Int(packedBytes[5])

        var callsign = ""
        for i in (0..<8).reversed() {
            let idx = (combined >> (i * 6)) & 0x3F
            if idx < chars.count {
                callsign.append(chars[chars.index(chars.startIndex, offsetBy: idx)])
            }
        }
        return callsign.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Compact Position Reporting

    private func decodeGlobalAirborneCPR(for icao: Int, newestOddEven: Int) -> CLLocationCoordinate2D? {
        guard let evenFrame = cprFrames[icao]?[0],
              let oddFrame = cprFrames[icao]?[1],
              case .airbornePosition(_, _, _, _, let evenLatCPR, let evenLonCPR) = evenFrame.payload,
              case .airbornePosition(_, _, _, _, let oddLatCPR, let oddLonCPR) = oddFrame.payload else {
            return nil
        }

        guard abs(evenFrame.timestamp.timeIntervalSince(oddFrame.timestamp)) <= 10 else { return nil }

        let yzEven = Double(evenLatCPR) / 131_072.0
        let yzOdd = Double(oddLatCPR) / 131_072.0
        let xzEven = Double(evenLonCPR) / 131_072.0
        let xzOdd = Double(oddLonCPR) / 131_072.0

        let j = floor((59.0 * yzEven) - (60.0 * yzOdd) + 0.5)
        var latEven = (360.0 / 60.0) * (positiveModulo(j, 60.0) + yzEven)
        var latOdd = (360.0 / 59.0) * (positiveModulo(j, 59.0) + yzOdd)
        if latEven >= 270 { latEven -= 360 }
        if latOdd >= 270 { latOdd -= 360 }

        guard nl(latEven) == nl(latOdd) else { return nil }

        let useOdd = newestOddEven == 1
        let lat = useOdd ? latOdd : latEven
        let ni = max(nl(lat) - (useOdd ? 1 : 0), 1)
        let m = floor((xzEven * Double(nl(lat) - 1)) - (xzOdd * Double(nl(lat))) + 0.5)
        var lon = (360.0 / Double(ni)) * (positiveModulo(m, Double(ni)) + (useOdd ? xzOdd : xzEven))
        if lon > 180 { lon -= 360 }

        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return coordinate
    }

    private func positiveModulo(_ value: Double, _ modulus: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private func extractBits(from bytes: [UInt8], startBit: Int, bitCount: Int) -> Int {
        guard bitCount > 0 else { return 0 }

        var value = 0
        for offset in 0..<bitCount {
            let absoluteBit = startBit + offset
            let byteIndex = absoluteBit / 8
            let bitIndex = 7 - (absoluteBit % 8)
            guard byteIndex < bytes.count else { break }
            let bit = (Int(bytes[byteIndex]) >> bitIndex) & 0x01
            value = (value << 1) | bit
        }
        return value
    }

    private func decodeIdentityCode(_ identityCode: Int) -> Int {
        let a = (((identityCode >> 7) & 1) << 2) | (((identityCode >> 9) & 1) << 1) | ((identityCode >> 11) & 1)
        let b = (((identityCode >> 1) & 1) << 2) | (((identityCode >> 3) & 1) << 1) | ((identityCode >> 5) & 1)
        let c = (((identityCode >> 8) & 1) << 2) | (((identityCode >> 10) & 1) << 1) | ((identityCode >> 12) & 1)
        let d = ((identityCode & 1) << 2) | (((identityCode >> 2) & 1) << 1) | ((identityCode >> 4) & 1)
        return (a * 1000) + (b * 100) + (c * 10) + d
    }

    private func decodeModeSAltitudeCode(_ altitudeCode: Int) -> Int? {
        if altitudeCode & 0x40 != 0 {
            return decodeMetricAltitude(from: altitudeCode)
        }

        if altitudeCode & 0x10 != 0 {
            let n = ((altitudeCode & 0x1F80) >> 2) |
                    ((altitudeCode & 0x20) >> 1) |
                    (altitudeCode & 0x0F)
            return n * 25 - 1000
        }

        return decodeGillhamAltitude(from: altitudeCode)
    }

    private func decodeMetricAltitude(from altitudeCode: Int) -> Int? {
        let meters = ((altitudeCode & 0x1F80) >> 1) | (altitudeCode & 0x3F)
        guard meters >= 0 else { return nil }
        return Int((Double(meters * 25) * 3.28084).rounded())
    }

    private func decodeGillhamAltitude(from altitudeCode: Int) -> Int? {
        let c1 = altitudeCode & 0x1000 != 0 ? 1 : 0
        let c2 = altitudeCode & 0x0400 != 0 ? 1 : 0
        let c4 = altitudeCode & 0x0100 != 0 ? 1 : 0
        let cHundredsCode = (c4 << 2) | (c2 << 1) | c1

        let gray500 =
            ((altitudeCode & 0x0002) != 0 ? 0b1000_0000 : 0) | // D2
            ((altitudeCode & 0x0001) != 0 ? 0b0100_0000 : 0) | // D4
            ((altitudeCode & 0x0800) != 0 ? 0b0010_0000 : 0) | // A1
            ((altitudeCode & 0x0200) != 0 ? 0b0001_0000 : 0) | // A2
            ((altitudeCode & 0x0080) != 0 ? 0b0000_1000 : 0) | // A4
            ((altitudeCode & 0x0020) != 0 ? 0b0000_0100 : 0) | // B1
            ((altitudeCode & 0x0008) != 0 ? 0b0000_0010 : 0) | // B2
            ((altitudeCode & 0x0004) != 0 ? 0b0000_0001 : 0)   // B4

        let fiveHundredIndex = grayToBinary(gray500) - 2
        let evenParity = (fiveHundredIndex & 1) == 0

        let hundredsOffset: Int?
        switch (evenParity, cHundredsCode) {
        case (true, 0b100): hundredsOffset = -200
        case (true, 0b110): hundredsOffset = -100
        case (true, 0b010): hundredsOffset = 0
        case (true, 0b011): hundredsOffset = 100
        case (true, 0b001): hundredsOffset = 200
        case (false, 0b001): hundredsOffset = -200
        case (false, 0b011): hundredsOffset = -100
        case (false, 0b010): hundredsOffset = 0
        case (false, 0b110): hundredsOffset = 100
        case (false, 0b100): hundredsOffset = 200
        default: hundredsOffset = nil
        }

        guard let hundredsOffset else { return nil }
        return fiveHundredIndex * 500 + hundredsOffset
    }

    private func grayToBinary(_ gray: Int) -> Int {
        var binary = gray
        var mask = gray >> 1
        while mask != 0 {
            binary ^= mask
            mask >>= 1
        }
        return binary
    }

    private func nl(_ latitude: Double) -> Int {
        let lat = abs(latitude)
        switch lat {
        case ..<10.47047130: return 59
        case ..<14.82817437: return 58
        case ..<18.18626357: return 57
        case ..<21.02939493: return 56
        case ..<23.54504487: return 55
        case ..<25.82924707: return 54
        case ..<27.93898710: return 53
        case ..<29.91135686: return 52
        case ..<31.77209708: return 51
        case ..<33.53993436: return 50
        case ..<35.22899598: return 49
        case ..<36.85025108: return 48
        case ..<38.41241892: return 47
        case ..<39.92256684: return 46
        case ..<41.38651832: return 45
        case ..<42.80914012: return 44
        case ..<44.19454951: return 43
        case ..<45.54626723: return 42
        case ..<46.86733252: return 41
        case ..<48.16039128: return 40
        case ..<49.42776439: return 39
        case ..<50.67150166: return 38
        case ..<51.89342469: return 37
        case ..<53.09516153: return 36
        case ..<54.27817472: return 35
        case ..<55.44378444: return 34
        case ..<56.59318756: return 33
        case ..<57.72747354: return 32
        case ..<58.84763776: return 31
        case ..<59.95459277: return 30
        case ..<61.04917774: return 29
        case ..<62.13216659: return 28
        case ..<63.20427479: return 27
        case ..<64.26616523: return 26
        case ..<65.31845310: return 25
        case ..<66.36171008: return 24
        case ..<67.39646774: return 23
        case ..<68.42322022: return 22
        case ..<69.44242631: return 21
        case ..<70.45451075: return 20
        case ..<71.45986473: return 19
        case ..<72.45884545: return 18
        case ..<73.45177442: return 17
        case ..<74.43893416: return 16
        case ..<75.42056257: return 15
        case ..<76.39684391: return 14
        case ..<77.36789461: return 13
        case ..<78.33374083: return 12
        case ..<79.29428225: return 11
        case ..<80.24923213: return 10
        case ..<81.19801349: return 9
        case ..<82.13956981: return 8
        case ..<83.07199445: return 7
        case ..<83.99173563: return 6
        case ..<84.89166191: return 5
        case ..<85.75541621: return 4
        case ..<86.53536998: return 3
        case ..<87.00000000: return 2
        default: return 1
        }
    }

    // MARK: - CRC-24 validation

    private func crc24(bytes: [UInt8]) -> UInt32 {
        let generator: UInt32 = 0xFFF409
        var crc: UInt32 = 0
        for byte in bytes {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 { crc ^= generator }
            }
        }
        return crc & 0xFF_FFFF
    }

    private func transmittedParity(bytes: [UInt8]) -> UInt32 {
        guard bytes.count >= 3 else { return 0 }
        return (UInt32(bytes[bytes.count - 3]) << 16) |
               (UInt32(bytes[bytes.count - 2]) << 8) |
               UInt32(bytes[bytes.count - 1])
    }

    private func hexToBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let nextIdx = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<nextIdx], radix: 16) else { return nil }
            result.append(byte)
            idx = nextIdx
        }
        return result
    }

    // MARK: - 1090 MHz PPM IQ extraction

    private func resetSampleBuffer(sampleRate: Double) {
        magnitudeCarry.removeAll(keepingCapacity: true)
        samplesSeen = 0
        searchedThroughAbsoluteStart = -1
        lastSampleRate = sampleRate
    }

    private func samplesFor(us: Double, sampleRate: Double) -> Int {
        max(1, Int(ceil(us * sampleRate / 1_000_000.0)))
    }

    private func isPreamble(at start: Int, in magnitudes: [Float], sampleRate: Double) -> Bool {
        preambleScore(at: start, in: magnitudes, sampleRate: sampleRate) != nil
    }

    private func preambleScore(at start: Int, in magnitudes: [Float], sampleRate: Double) -> Float? {
        let pulseWindows = [
            averageMagnitude(at: start, from: 0.0, to: 0.5, in: magnitudes, sampleRate: sampleRate),
            averageMagnitude(at: start, from: 1.0, to: 1.5, in: magnitudes, sampleRate: sampleRate),
            averageMagnitude(at: start, from: 3.5, to: 4.0, in: magnitudes, sampleRate: sampleRate),
            averageMagnitude(at: start, from: 4.5, to: 5.0, in: magnitudes, sampleRate: sampleRate)
        ]
        let quietWindows = [
            averageMagnitude(at: start, from: 0.5, to: 1.0, in: magnitudes, sampleRate: sampleRate),
            averageMagnitude(at: start, from: 1.5, to: 3.5, in: magnitudes, sampleRate: sampleRate),
            averageMagnitude(at: start, from: 4.0, to: 4.5, in: magnitudes, sampleRate: sampleRate),
            averageMagnitude(at: start, from: 5.0, to: 8.0, in: magnitudes, sampleRate: sampleRate)
        ]

        let high = pulseWindows.reduce(0, +) / Float(pulseWindows.count)
        let low = quietWindows.reduce(0, +) / Float(quietWindows.count)
        let weakestPulse = pulseWindows.min() ?? 0
        let strongestQuiet = quietWindows.max() ?? 0
        let contrast = high - low

        guard high > max(0.012, low * 2.2 + 0.008),
              weakestPulse > max(0.010, strongestQuiet * 1.6 + 0.006),
              contrast > max(0.006, low * 0.8) else {
            return nil
        }

        return contrast + (weakestPulse - strongestQuiet)
    }

    private func decodeMessageBytes(at start: Int, in magnitudes: [Float], sampleRate: Double) -> ([UInt8], Int)? {
        let preambleWindow = max(1, Int(round(sampleRate / 2_000_000.0)))
        var bestCandidate: (bytes: [UInt8], bitCount: Int, score: Float)?

        for delta in -preambleWindow...preambleWindow {
            let candidateStart = start + delta
            guard candidateStart >= 0 else { continue }
            guard preambleScore(at: candidateStart, in: magnitudes, sampleRate: sampleRate) != nil else { continue }

            guard let shortCandidate = decodeBits(
                at: candidateStart,
                bitCount: Self.shortMessageBitCount,
                in: magnitudes,
                sampleRate: sampleRate
            ), let shortBytes = bitsToBytes(shortCandidate.bits) else {
                continue
            }

            let df = Int(shortBytes[0]) >> 3
            guard isSupportedDownlinkFormat(df) else { continue }

            if !isLongMessageFormat(df) {
                if bestCandidate == nil || shortCandidate.score > bestCandidate!.score {
                    bestCandidate = (shortBytes, Self.shortMessageBitCount, shortCandidate.score)
                }
                continue
            }

            guard let longCandidate = decodeBits(
                at: candidateStart,
                bitCount: Self.longMessageBitCount,
                in: magnitudes,
                sampleRate: sampleRate
            ), let longBytes = bitsToBytes(longCandidate.bits) else {
                continue
            }

            if bestCandidate == nil || longCandidate.score > bestCandidate!.score {
                bestCandidate = (longBytes, Self.longMessageBitCount, longCandidate.score)
            }
        }

        if let bestCandidate {
            return (bestCandidate.bytes, bestCandidate.bitCount)
        }
        return nil
    }

    private func decodeBits(at start: Int, bitCount: Int, in magnitudes: [Float], sampleRate: Double) -> (bits: [Bool], score: Float)? {
        var bits: [Bool] = []
        bits.reserveCapacity(bitCount)
        var score: Float = 0

        for bitIndex in 0..<bitCount {
            let bitStartUs = Self.preambleDurationUs + Double(bitIndex) * Self.bitDurationUs
            let firstHalf = averageMagnitude(at: start, from: bitStartUs, to: bitStartUs + 0.5,
                                             in: magnitudes, sampleRate: sampleRate)
            let secondHalf = averageMagnitude(at: start, from: bitStartUs + 0.5, to: bitStartUs + 1.0,
                                              in: magnitudes, sampleRate: sampleRate)
            let stronger = max(firstHalf, secondHalf)
            let weaker = min(firstHalf, secondHalf)
            let contrast = stronger - weaker
            guard stronger > max(0.010, weaker * 1.22 + 0.004),
                  contrast > 0.003 else { return nil }
            bits.append(firstHalf > secondHalf)
            score += contrast
        }

        return (bits, score)
    }

    private func isSupportedDownlinkFormat(_ df: Int) -> Bool {
        switch df {
        case 0, 4, 5, 11, 16, 17, 18, 20, 21:
            return true
        default:
            return false
        }
    }

    private func isLongMessageFormat(_ df: Int) -> Bool {
        switch df {
        case 16, 17, 18, 20, 21:
            return true
        default:
            return false
        }
    }

    private func averageMagnitude(at start: Int, from startUs: Double, to endUs: Double,
                                  in magnitudes: [Float], sampleRate: Double) -> Float {
        let lo = start + Int(round(startUs * sampleRate / 1_000_000.0))
        let hi = start + max(Int(round(endUs * sampleRate / 1_000_000.0)), Int(round(startUs * sampleRate / 1_000_000.0)) + 1)
        guard lo >= 0, lo < magnitudes.count else { return 0 }

        let boundedHi = min(hi, magnitudes.count)
        guard boundedHi > lo else { return 0 }

        var sum: Float = 0
        for idx in lo..<boundedHi {
            sum += magnitudes[idx]
        }
        return sum / Float(boundedHi - lo)
    }

    private func bitsToBytes(_ bits: [Bool]) -> [UInt8]? {
        guard bits.count % 8 == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: bits.count / 8)
        for (idx, bit) in bits.enumerated() where bit {
            bytes[idx / 8] |= UInt8(0x80 >> (idx % 8))
        }
        return bytes
    }

    private func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

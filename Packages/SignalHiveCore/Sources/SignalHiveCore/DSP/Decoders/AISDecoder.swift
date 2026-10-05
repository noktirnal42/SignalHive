import Foundation
import CoreLocation

// MARK: - AIS Message types

public struct AISMessage: Sendable, Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let mmsi: Int
    public let messageType: Int
    public let payload: AISPayload

    public var callsign: String? {
        if case .staticVoyage(let v) = payload { return v.callsign }
        return nil
    }
    public var vesselName: String? {
        if case .staticVoyage(let v) = payload { return v.name }
        if case .staticDataReport(let r) = payload { return r.name }
        return nil
    }
    public var position: CLLocationCoordinate2D? {
        switch payload {
        case .positionReportA(let p): return p.coordinate
        case .positionReportB(let p): return p.coordinate
        default: return nil
        }
    }
}

public enum AISPayload: Sendable {
    case positionReportA(AISPositionReportA)
    case positionReportB(AISPositionReportB)
    case staticVoyage(AISStaticVoyage)
    case baseStation(AISBaseStation)
    case staticDataReport(AISStaticDataReport)
    case safetyMessage(String)
    case unknown
}

public struct AISPositionReportA: Sendable {
    public var navigationStatus: Int         // 0=underway, 1=anchor, etc.
    public var rateOfTurn: Float             // degrees/min
    public var speedOverGround: Float        // knots
    public var latitude: Double
    public var longitude: Double
    public var courseOverGround: Float       // degrees
    public var trueHeading: Int             // 0–359 degrees, 511=NA
    public var timestamp: Int               // seconds within minute

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    public var isValid: Bool {
        latitude != 91 && longitude != 181  // AIS invalid sentinel values
    }
}

public struct AISPositionReportB: Sendable {
    public var speedOverGround: Float
    public var latitude: Double
    public var longitude: Double
    public var courseOverGround: Float
    public var trueHeading: Int

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

public struct AISStaticVoyage: Sendable {
    public var imoNumber: Int
    public var callsign: String
    public var name: String
    public var shipType: Int
    public var dimensionToBow: Int
    public var dimensionToStern: Int
    public var dimensionToPort: Int
    public var dimensionToStarboard: Int
    public var draught: Float              // meters / 10
    public var destination: String
    public var etaMonth: Int
    public var etaDay: Int
    public var etaHour: Int
    public var etaMinute: Int
}

public struct AISBaseStation: Sendable {
    public var utcYear: Int
    public var utcMonth: Int
    public var utcDay: Int
    public var utcHour: Int
    public var utcMinute: Int
    public var utcSecond: Int
    public var latitude: Double
    public var longitude: Double
}

public struct AISStaticDataReport: Sendable {
    public var partNumber: Int
    public var name: String
    public var callsign: String
    public var shipType: Int
}

// MARK: - NMEA AIVDM/AIVDO sentence parser

/// Parses raw NMEA AIVDM sentences from demodulated AFSK 1200-baud HDLC frames.
/// In production, this wraps marnav (C++) via Swift-C++ interop.
/// This Swift implementation covers the most common message types.
public final class AISDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "AIS"
    public let requiredBandwidth: Double = 25_000  // 25 kHz NFM channel
    public var timestampProvider: @Sendable () -> Date = { .now }

    private static let nominalFrequencyHz = 162_025_000.0
    private static let baudRate = 9_600.0
    private static let hdlcFlag = [0, 1, 1, 1, 1, 1, 1, 0]

    // AFSK demodulator state (shared AFSKDemodulator from DSP/AFSK)
    private var afskDemod: AFSKDemodulator
    private var hdlcDecoder: HDLCDecoder
    private var nmeaBuffer: [String] = []
    private var fmPreviousSample = ComplexFloat(i: 1, q: 0)
    private var symbolSamples: [Float] = []
    private var lastNRZILevel: Int?
    private var logicalBitBuffer: [Int] = []

    // Multi-part message reassembly
    private var multipartBuffer: [Int: [String]] = [:]

    // Published vessel tracks
    private var vessels: [Int: AISVesselTrack] = [:]

    public init() {
        self.afskDemod = AFSKDemodulator(sampleRate: 48_000, baudRate: 9_600, markFreq: 1200, spaceFreq: 2200)
        self.hdlcDecoder = HDLCDecoder()
    }

    public func reset() {
        afskDemod = AFSKDemodulator(sampleRate: 48_000, baudRate: 9_600, markFreq: 1200, spaceFreq: 2200)
        hdlcDecoder = HDLCDecoder()
        nmeaBuffer.removeAll(keepingCapacity: true)
        fmPreviousSample = ComplexFloat(i: 1, q: 0)
        symbolSamples.removeAll(keepingCapacity: true)
        lastNRZILevel = nil
        logicalBitBuffer.removeAll(keepingCapacity: true)
        multipartBuffer.removeAll(keepingCapacity: true)
        vessels.removeAll(keepingCapacity: true)
        timestampProvider = { .now }
    }

    public func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard sampleRate >= Self.baudRate, !iq.isEmpty else { return [] }

        let audio = fmDiscriminator(iq: iq, sampleRate: sampleRate)
        let nrziLevels = recoverNRZILevels(from: audio, sampleRate: sampleRate)
        for level in nrziLevels {
            if let previous = lastNRZILevel {
                logicalBitBuffer.append(level == previous ? 1 : 0)
            }
            lastNRZILevel = level
        }

        let frameBits = extractHDLCFrames()
        var messages: [DecodedMessage] = []

        for bits in frameBits {
            // Only a frame whose check passes is a message; between two flag patterns noise is not.
            guard let payload = AISFrameCheck.payload(fromFrame: bits),
                  let nmea = makeAIVDMSentence(fromFrameBits: payload),
                  let message = parseNMEA(nmea) else { continue }
            messages.append(DecodedMessage(
                timestamp: message.timestamp,
                frequency: Self.nominalFrequencyHz,
                mode: identifier,
                payload: .ais(message)
            ))
        }

        return messages
    }

    // MARK: - NMEA sentence → AISMessage

    public func parseNMEA(_ sentence: String) -> AISMessage? {
        guard sentence.hasPrefix("!AIVDM") || sentence.hasPrefix("!AIVDO") else { return nil }

        // Validate NMEA XOR checksum (bytes between '!' and '*', exclusive)
        if let starIdx = sentence.lastIndex(of: "*") {
            let checksumStart = sentence.index(after: starIdx)
            let checksumSlice = sentence[checksumStart...]
            if checksumSlice.count >= 2,
               let expected = UInt8(checksumSlice.prefix(2), radix: 16) {
                let bodyStart = sentence.index(after: sentence.startIndex)
                let computed = sentence[bodyStart..<starIdx].utf8.reduce(UInt8(0)) { $0 ^ $1 }
                guard computed == expected else { return nil }
            }
        }

        let parts = sentence.components(separatedBy: ",")
        guard parts.count >= 7 else { return nil }

        let fragmentCount = Int(parts[1]) ?? 1
        _ = Int(parts[2]) ?? 1  // fragment number — reserved for multi-sentence reassembly
        let sequentialId  = parts[3]
        let channel       = parts[4]    // A or B
        let payload       = parts[5]
        let fillBits      = Int(String(parts[6].prefix(1))) ?? 0

        if fragmentCount > 1 {
            // Multi-part: buffer until all fragments received
            let key = (Int(sequentialId) ?? 0)
            var parts = multipartBuffer[key] ?? []
            parts.append(payload)
            if parts.count == fragmentCount {
                multipartBuffer.removeValue(forKey: key)
                let message = decodePayload(parts.joined(), fillBits: fillBits, channel: channel)
                if let message { apply(message: message) }
                return message
            } else {
                multipartBuffer[key] = parts
                return nil
            }
        } else {
            let message = decodePayload(payload, fillBits: fillBits, channel: channel)
            if let message { apply(message: message) }
            return message
        }
    }

    public func allVesselTracks() async -> [AISVesselTrack] {
        vessels.values.sorted { $0.id < $1.id }
    }

    public func apply(message: AISMessage) {
        var vessel = vessels[message.mmsi] ?? AISVesselTrack(id: message.mmsi)
        vessel.lastUpdate = message.timestamp

        switch message.payload {
        case .positionReportA(let p):
            vessel.positions.append(AISPositionRecord(
                timestamp: message.timestamp,
                coordinate: p.coordinate,
                speedOverGround: p.speedOverGround,
                courseOverGround: p.courseOverGround,
                heading: p.trueHeading,
                navigationStatus: p.navigationStatus
            ))
            if vessel.positions.count > 100 { vessel.positions.removeFirst() }
        case .positionReportB(let p):
            vessel.positions.append(AISPositionRecord(
                timestamp: message.timestamp,
                coordinate: p.coordinate,
                speedOverGround: p.speedOverGround,
                courseOverGround: p.courseOverGround,
                heading: p.trueHeading,
                navigationStatus: 0
            ))
            if vessel.positions.count > 100 { vessel.positions.removeFirst() }
        case .staticVoyage(let v):
            vessel.name = v.name
            vessel.callsign = v.callsign
            vessel.shipType = v.shipType
            vessel.destination = v.destination
        case .staticDataReport(let r):
            vessel.name = r.name
            vessel.callsign = r.callsign
            vessel.shipType = r.shipType
        default:
            break
        }

        vessels[message.mmsi] = vessel
    }

    // MARK: - Payload bit extraction

    private func decodePayload(_ encoded: String, fillBits: Int, channel: String) -> AISMessage? {
        var bits = aisToBits(encoded: encoded, fillBits: fillBits)
        guard bits.count >= 6 else { return nil }

        let messageType = extractBits(bits, from: 0, length: 6)
        let mmsi        = extractBits(bits, from: 8, length: 30)
        guard bits.count >= minimumPayloadBits(for: messageType) else { return nil }

        let payload: AISPayload
        switch messageType {
        case 1, 2, 3:
            payload = .positionReportA(decodePositionA(&bits))
        case 18, 19:
            payload = .positionReportB(decodePositionB(&bits))
        case 5:
            payload = .staticVoyage(decodeStaticVoyage(&bits))
        case 4, 11:
            payload = .baseStation(decodeBaseStation(&bits))
        case 12, 14:
            let text = extractString(&bits, from: 40, length: min(bits.count - 40, 968))
            payload = .safetyMessage(text)
        case 24:
            payload = .staticDataReport(decodeStaticDataReport(&bits))
        default:
            payload = .unknown
        }

        return AISMessage(
            timestamp: timestampProvider(),
            mmsi: mmsi,
            messageType: messageType,
            payload: payload
        )
    }

    private func minimumPayloadBits(for messageType: Int) -> Int {
        switch messageType {
        case 1, 2, 3: return 168
        case 4, 11: return 168
        case 5: return 424
        case 12, 14: return 40
        case 18: return 168
        case 19: return 312
        case 24: return 40
        default: return 38
        }
    }

    private func decodePositionA(_ bits: inout [Int]) -> AISPositionReportA {
        let p = AISPositionReportA(
            navigationStatus: extractBits(bits, from: 38, length: 4),
            rateOfTurn: Float(extractSignedBits(bits, from: 42, length: 8)),
            speedOverGround: Float(extractBits(bits, from: 50, length: 10)) / 10.0,
            latitude: Double(extractSignedBits(bits, from: 89, length: 27)) / 600_000.0,
            longitude: Double(extractSignedBits(bits, from: 61, length: 28)) / 600_000.0,
            courseOverGround: Float(extractBits(bits, from: 116, length: 12)) / 10.0,
            trueHeading: extractBits(bits, from: 128, length: 9),
            timestamp: extractBits(bits, from: 137, length: 6)
        )
        return p
    }

    private func decodePositionB(_ bits: inout [Int]) -> AISPositionReportB {
        return AISPositionReportB(
            speedOverGround: Float(extractBits(bits, from: 46, length: 10)) / 10.0,
            latitude: Double(extractSignedBits(bits, from: 85, length: 27)) / 600_000.0,
            longitude: Double(extractSignedBits(bits, from: 57, length: 28)) / 600_000.0,
            courseOverGround: Float(extractBits(bits, from: 112, length: 12)) / 10.0,
            trueHeading: extractBits(bits, from: 124, length: 9)
        )
    }

    private func decodeStaticVoyage(_ bits: inout [Int]) -> AISStaticVoyage {
        return AISStaticVoyage(
            imoNumber: extractBits(bits, from: 40, length: 30),
            callsign: extractString(&bits, from: 70, length: 42).trimmingCharacters(in: .whitespaces),
            name: extractString(&bits, from: 112, length: 120).trimmingCharacters(in: .whitespaces),
            shipType: extractBits(bits, from: 232, length: 8),
            dimensionToBow: extractBits(bits, from: 240, length: 9),
            dimensionToStern: extractBits(bits, from: 249, length: 9),
            dimensionToPort: extractBits(bits, from: 258, length: 6),
            dimensionToStarboard: extractBits(bits, from: 264, length: 6),
            draught: Float(extractBits(bits, from: 294, length: 8)) / 10.0,
            destination: extractString(&bits, from: 302, length: 120).trimmingCharacters(in: .whitespaces),
            etaMonth: extractBits(bits, from: 274, length: 4),
            etaDay: extractBits(bits, from: 278, length: 5),
            etaHour: extractBits(bits, from: 283, length: 5),
            etaMinute: extractBits(bits, from: 288, length: 6)
        )
    }

    private func decodeBaseStation(_ bits: inout [Int]) -> AISBaseStation {
        return AISBaseStation(
            utcYear: extractBits(bits, from: 38, length: 14),
            utcMonth: extractBits(bits, from: 52, length: 4),
            utcDay: extractBits(bits, from: 56, length: 5),
            utcHour: extractBits(bits, from: 61, length: 5),
            utcMinute: extractBits(bits, from: 66, length: 6),
            utcSecond: extractBits(bits, from: 72, length: 6),
            latitude: Double(extractSignedBits(bits, from: 107, length: 27)) / 600_000.0,
            longitude: Double(extractSignedBits(bits, from: 79, length: 28)) / 600_000.0
        )
    }

    private func decodeStaticDataReport(_ bits: inout [Int]) -> AISStaticDataReport {
        let part = extractBits(bits, from: 38, length: 2)
        if part == 0 {
            return AISStaticDataReport(
                partNumber: 0,
                name: extractString(&bits, from: 40, length: 120),
                callsign: "",
                shipType: extractBits(bits, from: 40, length: 8)
            )
        } else {
            return AISStaticDataReport(
                partNumber: 1,
                name: "",
                callsign: extractString(&bits, from: 48, length: 42),
                shipType: 0
            )
        }
    }

    // MARK: - Bit manipulation helpers

    private func aisToBits(encoded: String, fillBits: Int) -> [Int] {
        var bits: [Int] = []
        for char in encoded.unicodeScalars {
            var v = Int(char.value) - 48
            if v > 40 { v -= 8 }
            for b in (0..<6).reversed() {
                bits.append((v >> b) & 1)
            }
        }
        if fillBits > 0 { bits.removeLast(fillBits) }
        return bits
    }

    private func extractBits(_ bits: [Int], from start: Int, length: Int) -> Int {
        guard start + length <= bits.count else { return 0 }
        var result = 0
        for i in 0..<length {
            result = (result << 1) | bits[start + i]
        }
        return result
    }

    private func extractSignedBits(_ bits: [Int], from start: Int, length: Int) -> Int {
        guard start >= 0, start < bits.count, start + length <= bits.count else { return 0 }
        let raw = extractBits(bits, from: start, length: length)
        if bits[start] == 1 {
            return raw - (1 << length)  // two's complement
        }
        return raw
    }

    private func extractString(_ bits: inout [Int], from start: Int, length: Int) -> String {
        var result = ""
        let charCount = length / 6
        for i in 0..<charCount {
            let charBits = extractBits(bits, from: start + i * 6, length: 6)
            let charCode = charBits < 32 ? charBits + 64 : charBits
            if let scalar = Unicode.Scalar(charCode), charCode > 0 {
                result.append(Character(scalar))
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "@\0 "))
    }

    // MARK: - Native AIS GMSK/FM first-pass demodulation

    private func fmDiscriminator(iq: [ComplexFloat], sampleRate: Double) -> [Float] {
        var audio: [Float] = []
        audio.reserveCapacity(iq.count)

        let scale = Float(sampleRate) / (2 * Float.pi)
        for sample in iq {
            let prod = sample * ComplexFloat(i: fmPreviousSample.i, q: -fmPreviousSample.q)
            audio.append(atan2f(prod.q, prod.i) * scale)
            fmPreviousSample = sample
        }
        return audio
    }

    private func recoverNRZILevels(from audio: [Float], sampleRate: Double) -> [Int] {
        let samplesPerSymbol = max(1, Int(round(sampleRate / Self.baudRate)))
        symbolSamples.append(contentsOf: audio)

        var levels: [Int] = []
        while symbolSamples.count >= samplesPerSymbol {
            let symbol = symbolSamples.prefix(samplesPerSymbol)
            let average = symbol.reduce(Float(0), +) / Float(samplesPerSymbol)
            levels.append(average >= 0 ? 1 : 0)
            symbolSamples.removeFirst(samplesPerSymbol)
        }

        let maxCarry = samplesPerSymbol * 2
        if symbolSamples.count > maxCarry {
            symbolSamples = Array(symbolSamples.suffix(maxCarry))
        }
        return levels
    }

    private func extractHDLCFrames() -> [[Int]] {
        var flagStarts: [Int] = []
        guard logicalBitBuffer.count >= Self.hdlcFlag.count else { return [] }

        for idx in 0...(logicalBitBuffer.count - Self.hdlcFlag.count) {
            if Array(logicalBitBuffer[idx..<(idx + Self.hdlcFlag.count)]) == Self.hdlcFlag {
                flagStarts.append(idx)
            }
        }

        guard flagStarts.count >= 2 else {
            if logicalBitBuffer.count > 4096 {
                logicalBitBuffer = Array(logicalBitBuffer.suffix(64))
            }
            return []
        }

        var frames: [[Int]] = []
        for pairIndex in 0..<(flagStarts.count - 1) {
            let payloadStart = flagStarts[pairIndex] + Self.hdlcFlag.count
            let payloadEnd = flagStarts[pairIndex + 1]
            guard payloadEnd > payloadStart else { continue }
            let stuffedBits = Array(logicalBitBuffer[payloadStart..<payloadEnd])
            if let unstuffed = unstuffHDLCBits(stuffedBits), unstuffed.count >= 38 {
                frames.append(unstuffed)
            }
        }

        if let lastFlag = flagStarts.last {
            logicalBitBuffer = Array(logicalBitBuffer[lastFlag...])
        }
        return frames
    }

    private func unstuffHDLCBits(_ bits: [Int]) -> [Int]? {
        var result: [Int] = []
        var consecutiveOnes = 0

        var idx = 0
        while idx < bits.count {
            let bit = bits[idx]
            if bit == 1 {
                consecutiveOnes += 1
                result.append(bit)
                if consecutiveOnes > 6 { return nil }
            } else {
                if consecutiveOnes == 5 {
                    consecutiveOnes = 0
                    idx += 1
                    continue
                }
                consecutiveOnes = 0
                result.append(bit)
            }
            idx += 1
        }

        return result
    }

    private func makeAIVDMSentence(fromFrameBits bits: [Int]) -> String? {
        guard bits.count >= 38 else { return nil }

        let fillBits = (6 - (bits.count % 6)) % 6
        let padded = bits + Array(repeating: 0, count: fillBits)
        var payload = ""

        for offset in stride(from: 0, to: padded.count, by: 6) {
            let value = extractBits(padded, from: offset, length: 6)
            let scalar = value < 40 ? value + 48 : value + 56
            guard let unicode = UnicodeScalar(scalar) else { return nil }
            payload.append(Character(unicode))
        }

        let body = "AIVDM,1,1,,A,\(payload),\(fillBits)"
        let checksum = body.utf8.reduce(UInt8(0)) { $0 ^ $1 }
        return String(format: "!%@*%02X", body, checksum)
    }
}

// MARK: - Vessel Track

public struct AISVesselTrack: Identifiable, Hashable, Sendable {
    public let id: Int  // MMSI
    public var name: String = ""
    public var callsign: String = ""
    public var shipType: Int = 0
    public var destination: String = ""
    public var positions: [AISPositionRecord] = []
    public var lastUpdate: Date = .now
    public var isDark: Bool = false
    public var isAnomaly: Bool = false

    public var latestPosition: AISPositionRecord? { positions.last }
    public var mmsi: Int { id }
    public var lastCoordinate: CLLocationCoordinate2D? { latestPosition?.coordinate }
    public var speedOverGround: Float? { latestPosition?.speedOverGround }
    public var courseOverGround: Float? { latestPosition?.courseOverGround }
    public var lastSeen: Date { lastUpdate }

    public static func == (lhs: AISVesselTrack, rhs: AISVesselTrack) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct AISPositionRecord: Sendable {
    public var timestamp: Date
    public var coordinate: CLLocationCoordinate2D
    public var speedOverGround: Float
    public var courseOverGround: Float
    public var heading: Int
    public var navigationStatus: Int
}

// MARK: - Frame check

/// What makes a run of bits between two HDLC flags an AIS message: its 16-bit frame check sequence (CRC-16/X.25, sent low bit
/// first) must come out right, and its message type must be one AIS defines (1 to 27). Without this, the noise between any two
/// flag patterns (which turn up every few hundred bits) was reported as a vessel.
enum AISFrameCheck {
    /// The CRC register after the bits, in the order they were sent (the reflected form of the 0x1021 polynomial).
    static func register(_ bits: [Int]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for bit in bits {
            let mix = (crc ^ UInt16(bit & 1)) & 1
            crc >>= 1
            if mix == 1 { crc ^= 0x8408 }
        }
        return crc
    }

    /// The frame check sequence for a message: the register, inverted.
    static func checksum(_ bits: [Int]) -> UInt16 { ~register(bits) }

    /// The message (without its check) if the frame passes: run over message and check together, the register ends at 0xF0B8.
    static func payload(fromFrame bits: [Int]) -> [Int]? {
        let checkBits = 16
        guard bits.count >= checkBits + 38, register(bits) == 0xF0B8 else { return nil }
        let message = Array(bits.dropLast(checkBits))
        let type = message.prefix(6).reduce(0) { $0 << 1 | ($1 & 1) }
        return (1...27).contains(type) ? message : nil
    }
}

// MARK: - HDLC Decoder stub

final class HDLCDecoder: @unchecked Sendable {
    func decode(_ bits: [UInt8]) -> [Data] { [] }
}
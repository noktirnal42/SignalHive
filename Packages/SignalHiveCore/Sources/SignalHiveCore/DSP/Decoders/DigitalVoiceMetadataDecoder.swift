import Foundation

public enum DigitalVoiceMode: String, Sendable, Codable, CaseIterable {
    case dmr = "DMR"
    case dstar = "D-STAR"
    case nxdn = "NXDN"
    case p25Phase1 = "P25 Phase 1"
    case p25Phase2 = "P25 Phase 2"
    case tetra = "TETRA"
}

public struct DigitalVoiceFrame: Identifiable, Sendable, Codable, Hashable {
    public let id = UUID()
    public var timestamp: Date
    public var mode: DigitalVoiceMode
    public var sourceID: String?
    public var destinationID: String?
    public var talkgroup: String?
    public var slot: Int?
    public var colorCode: Int?
    public var nac: String?
    public var wacn: String?
    public var systemID: String?
    public var mcc: String?
    public var mnc: String?
    public var gssi: String?
    public var callsign: String?
    public var message: String?
    public var frameType: String?
    public var isEncrypted: Bool
    public var rawLine: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case mode
        case sourceID
        case destinationID
        case talkgroup
        case slot
        case colorCode
        case nac
        case wacn
        case systemID
        case mcc
        case mnc
        case gssi
        case callsign
        case message
        case frameType
        case isEncrypted
        case rawLine
    }

    public init(
        timestamp: Date = .now,
        mode: DigitalVoiceMode,
        sourceID: String? = nil,
        destinationID: String? = nil,
        talkgroup: String? = nil,
        slot: Int? = nil,
        colorCode: Int? = nil,
        nac: String? = nil,
        wacn: String? = nil,
        systemID: String? = nil,
        mcc: String? = nil,
        mnc: String? = nil,
        gssi: String? = nil,
        callsign: String? = nil,
        message: String? = nil,
        frameType: String? = nil,
        isEncrypted: Bool = false,
        rawLine: String
    ) {
        self.timestamp = timestamp
        self.mode = mode
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.talkgroup = talkgroup
        self.slot = slot
        self.colorCode = colorCode
        self.nac = nac
        self.wacn = wacn
        self.systemID = systemID
        self.mcc = mcc
        self.mnc = mnc
        self.gssi = gssi
        self.callsign = callsign
        self.message = message
        self.frameType = frameType
        self.isEncrypted = isEncrypted
        self.rawLine = rawLine
    }
}

public final class DigitalVoiceMetadataDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "Digital Voice Metadata"
    public let requiredBandwidth: Double = 12_500
    public var timestampProvider: @Sendable () -> Date = { .now }
    public var iqBridge: any DecoderIQBridge

    private var recentFrames: [DigitalVoiceFrame] = []
    private static let maxRecentFrames = 500

    public init(iqBridge: (any DecoderIQBridge)? = nil) {
        self.iqBridge = iqBridge ?? Self.defaultIQBridge()
    }

    public func reset() {
        recentFrames.removeAll(keepingCapacity: true)
        timestampProvider = { .now }
    }

    public func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard !iq.isEmpty else { return [] }
        let request = DecoderIQBridgeRequest(
            kind: .digitalVoice,
            decoderIdentifier: identifier,
            iqSamples: iq,
            sampleRate: sampleRate
        )
        guard let output = iqBridge.decode(request), !output.isEmpty else { return [] }
        return processBridgeOutput(output)
    }

    public func processBridgeOutput(_ text: String, frequency: Double = 0) -> [DecodedMessage] {
        let frames = Self.parseBridgeOutput(text, timestamp: timestampProvider())
        recentFrames.append(contentsOf: frames)
        if recentFrames.count > Self.maxRecentFrames {
            recentFrames.removeFirst(recentFrames.count - Self.maxRecentFrames)
        }

        return frames.map { frame in
            DecodedMessage(
                timestamp: frame.timestamp,
                frequency: frequency,
                mode: frame.mode.rawValue,
                payload: .digitalVoice(frame)
            )
        }
    }

    public func allFrames() -> [DigitalVoiceFrame] {
        recentFrames
    }

    public static func parseBridgeOutput(_ text: String, timestamp: Date = .now) -> [DigitalVoiceFrame] {
        text
            .split(whereSeparator: \.isNewline)
            .flatMap { parseLine(String($0), timestamp: timestamp) }
    }

    private static func parseLine(_ line: String, timestamp: Date) -> [DigitalVoiceFrame] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains(":DMR>") {
            return parseDSDccDMRLine(trimmed, timestamp: timestamp)
        }

        if trimmed.contains(":DST>"), let dstarFrame = parseDSDccDStarLine(trimmed, timestamp: timestamp) {
            return [dstarFrame]
        }

        let mode = detectMode(in: trimmed)
        guard let mode else { return [] }

        let fields = keyValueFields(in: trimmed)
        return [DigitalVoiceFrame(
            timestamp: timestamp,
            mode: mode,
            sourceID: first(fields, ["src", "source", "sourceid", "rid", "radio", "from"]),
            destinationID: first(fields, ["dst", "dest", "destination", "target", "to", "urcall", "yourcall"]),
            talkgroup: first(fields, ["tg", "talkgroup", "group"]),
            slot: intField(fields, ["slot", "ts", "timeslot"]),
            colorCode: intField(fields, ["cc", "colorcode", "colourcode"]),
            nac: first(fields, ["nac"]),
            wacn: first(fields, ["wacn"]),
            systemID: first(fields, ["sys", "system", "systemid"]),
            mcc: first(fields, ["mcc"]),
            mnc: first(fields, ["mnc"]),
            gssi: first(fields, ["gssi"]),
            callsign: first(fields, ["callsign", "call", "mycall", "urcall"]),
            message: message(from: trimmed, fields: fields),
            frameType: first(fields, ["type", "frame", "burst", "calltype"]),
            isEncrypted: boolField(fields, ["enc", "encrypted", "privacy", "secure"]) ?? trimmed.localizedCaseInsensitiveContains(" encrypted"),
            rawLine: trimmed
        )]
    }

    private static func detectMode(in line: String) -> DigitalVoiceMode? {
        let upper = line.uppercased()
        if upper.contains("P25P2") || upper.contains("P25 PHASE 2") || upper.contains("PHASE2") {
            return .p25Phase2
        }
        if upper.contains("P25") {
            return .p25Phase1
        }
        if upper.contains("D-STAR") || upper.contains("DSTAR") {
            return .dstar
        }
        if upper.contains("NXDN") {
            return .nxdn
        }
        if upper.contains("TETRA") {
            return .tetra
        }
        if upper.contains("DMR") {
            return .dmr
        }
        return nil
    }

    private static func keyValueFields(in line: String) -> [String: String] {
        var fields: [String: String] = [:]
        let separators = CharacterSet(charactersIn: " ,;\t")
        for token in line.components(separatedBy: separators) {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = normalizeKey(parts[0])
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]()"))
            if !key.isEmpty, !value.isEmpty {
                fields[key] = value
            }
        }
        return fields
    }

    private static func first(_ fields: [String: String], _ keys: [String]) -> String? {
        keys.lazy.map(normalizeKey).compactMap { fields[$0] }.first
    }

    private static func intField(_ fields: [String: String], _ keys: [String]) -> Int? {
        guard let value = first(fields, keys) else { return nil }
        return Int(value)
    }

    private static func boolField(_ fields: [String: String], _ keys: [String]) -> Bool? {
        guard let value = first(fields, keys)?.lowercased() else { return nil }
        if ["1", "yes", "true", "y", "encrypted", "privacy"].contains(value) {
            return true
        }
        if ["0", "no", "false", "n", "clear"].contains(value) {
            return false
        }
        return nil
    }

    private static func message(from line: String, fields: [String: String]) -> String? {
        if let explicit = first(fields, ["msg", "message", "text", "sds"]) {
            return explicit.replacingOccurrences(of: "_", with: " ")
        }
        guard let range = line.range(of: "message:", options: [.caseInsensitive]) else {
            return nil
        }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func parseDSDccDMRLine(_ line: String, timestamp: Date) -> [DigitalVoiceFrame] {
        let patterns = [
            ("S1", 1),
            ("S2", 2)
        ]

        return patterns.compactMap { label, slot in
            guard let range = line.range(of: "\(label):") else { return nil }
            let nextRange = line[range.upperBound...].range(of: slot == 1 ? "S2:" : "")
            let segment: String
            if let nextRange, slot == 1 {
                segment = String(line[range.upperBound..<nextRange.lowerBound])
            } else {
                segment = String(line[range.upperBound...])
            }
            return parseDSDccDMRSlot(segment, line: line, timestamp: timestamp, slot: slot)
        }
    }

    private static func parseDSDccDMRSlot(
        _ segment: String,
        line: String,
        timestamp: Date,
        slot: Int
    ) -> DigitalVoiceFrame? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return nil }

        let status = String(trimmed.prefix(1))
        let remainderAfterStatus = trimmed.dropFirst()
        let colorCode = Int(remainderAfterStatus.prefix(2))
        let remainder = remainderAfterStatus.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        let slotType = String(remainder.prefix(3)).trimmingCharacters(in: .whitespaces)
        guard !slotType.isEmpty else { return nil }

        let payload = remainder.dropFirst(min(3, remainder.count)).trimmingCharacters(in: .whitespaces)
        let payloadParts = payload.split(separator: ">", maxSplits: 1).map(String.init)

        var sourceID: String?
        var destinationID: String?
        var talkgroup: String?

        if payloadParts.count == 2 {
            sourceID = normalizeDigits(payloadParts[0])
            let destinationPart = payloadParts[1]
            if let first = destinationPart.first, first == "G" || first == "U" {
                destinationID = normalizeDigits(String(destinationPart.dropFirst()))
                if first == "G" {
                    talkgroup = destinationID
                }
            } else {
                destinationID = normalizeDigits(destinationPart)
            }
        }

        return DigitalVoiceFrame(
            timestamp: timestamp,
            mode: .dmr,
            sourceID: sourceID,
            destinationID: destinationID,
            talkgroup: talkgroup,
            slot: slot,
            colorCode: colorCode,
            message: slotType == "IDL" ? "Idle slot" : nil,
            frameType: slotType,
            isEncrypted: status == "*" && slotType.localizedCaseInsensitiveContains("enc"),
            rawLine: line
        )
    }

    private static func parseDSDccDStarLine(_ line: String, timestamp: Date) -> DigitalVoiceFrame? {
        guard let markerRange = line.range(of: ":DST>") else { return nil }
        let payload = String(line[markerRange.upperBound...])
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let route = parts.first else { return nil }

        let routePieces = route.split(separator: ">", maxSplits: 1).map(String.init)
        guard routePieces.count == 2 else { return nil }

        let originPart = routePieces[0]
        let destinationPart = routePieces[1].trimmingCharacters(in: .whitespaces)
        let originPieces = originPart.split(separator: "/", maxSplits: 1).map(String.init)
        let callsign = originPieces.first?.trimmingCharacters(in: .whitespaces)
        let suffix = originPieces.dropFirst().first?.trimmingCharacters(in: .whitespaces)
        let message = parts.dropFirst(2).first?.trimmingCharacters(in: .whitespaces)

        return DigitalVoiceFrame(
            timestamp: timestamp,
            mode: .dstar,
            destinationID: destinationPart.isEmpty ? nil : destinationPart,
            callsign: callsign?.isEmpty == false ? callsign : nil,
            message: message?.isEmpty == false ? message : nil,
            frameType: suffix?.isEmpty == false ? "suffix:\(suffix!)" : nil,
            rawLine: line
        )
    }

    private static func normalizeDigits(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    private static func defaultIQBridge() -> any DecoderIQBridge {
        #if os(macOS)
        if let bridge = DecoderToolPresets.digitalVoiceDSDcc.makeBridge() {
            return bridge
        }
        #endif
        return UnavailableDecoderIQBridge()
    }
}

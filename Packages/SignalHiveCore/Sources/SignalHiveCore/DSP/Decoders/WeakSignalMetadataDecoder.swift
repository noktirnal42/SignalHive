import Foundation

public enum WeakSignalMode: String, Sendable, Codable, CaseIterable {
    case ft8 = "FT8"
    case ft4 = "FT4"
    case wspr = "WSPR"
}

public struct WeakSignalFrame: Identifiable, Sendable, Codable, Hashable {
    public let id = UUID()
    public var timestamp: Date
    public var mode: WeakSignalMode
    public var frequencyHz: Double?
    public var audioFrequencyHz: Double?
    public var snrDB: Int?
    public var timeOffsetSec: Double?
    public var driftHzPerMinute: Double?
    public var callsign: String?
    public var grid: String?
    public var dxCallsign: String?
    public var report: String?
    public var powerDBm: Int?
    public var message: String
    public var rawLine: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case mode
        case frequencyHz
        case audioFrequencyHz
        case snrDB
        case timeOffsetSec
        case driftHzPerMinute
        case callsign
        case grid
        case dxCallsign
        case report
        case powerDBm
        case message
        case rawLine
    }

    public init(
        timestamp: Date = .now,
        mode: WeakSignalMode,
        frequencyHz: Double? = nil,
        audioFrequencyHz: Double? = nil,
        snrDB: Int? = nil,
        timeOffsetSec: Double? = nil,
        driftHzPerMinute: Double? = nil,
        callsign: String? = nil,
        grid: String? = nil,
        dxCallsign: String? = nil,
        report: String? = nil,
        powerDBm: Int? = nil,
        message: String,
        rawLine: String
    ) {
        self.timestamp = timestamp
        self.mode = mode
        self.frequencyHz = frequencyHz
        self.audioFrequencyHz = audioFrequencyHz
        self.snrDB = snrDB
        self.timeOffsetSec = timeOffsetSec
        self.driftHzPerMinute = driftHzPerMinute
        self.callsign = callsign
        self.grid = grid
        self.dxCallsign = dxCallsign
        self.report = report
        self.powerDBm = powerDBm
        self.message = message
        self.rawLine = rawLine
    }
}

public final class WeakSignalMetadataDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "Weak Signal Metadata"
    public let requiredBandwidth: Double = 3_000
    public var timestampProvider: @Sendable () -> Date = { .now }
    public var iqBridge: any DecoderIQBridge

    private var recentFrames: [WeakSignalFrame] = []
    private static let maxRecentFrames = 500

    public init(iqBridge: any DecoderIQBridge = UnavailableDecoderIQBridge()) {
        self.iqBridge = iqBridge
    }

    public func reset() {
        recentFrames.removeAll(keepingCapacity: true)
        timestampProvider = { .now }
    }

    public func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard !iq.isEmpty else { return [] }
        let request = DecoderIQBridgeRequest(
            kind: .weakSignal,
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
                frequency: frame.frequencyHz ?? frequency,
                mode: frame.mode.rawValue,
                payload: .weakSignal(frame)
            )
        }
    }

    public func allFrames() -> [WeakSignalFrame] {
        recentFrames
    }

    public static func parseBridgeOutput(_ text: String, timestamp: Date = .now) -> [WeakSignalFrame] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0), timestamp: timestamp) }
    }

    private static func parseLine(_ line: String, timestamp: Date) -> WeakSignalFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let keyed = parseKeyValueLine(trimmed, timestamp: timestamp) {
            return keyed
        }
        return parseWSJTXLine(trimmed, timestamp: timestamp)
    }

    private static func parseKeyValueLine(_ line: String, timestamp: Date) -> WeakSignalFrame? {
        let fields = keyValueFields(in: line)
        guard !fields.isEmpty,
              let modeValue = first(fields, ["mode", "decoder", "protocol"]),
              let mode = mode(from: modeValue) else {
            return nil
        }

        let message = first(fields, ["msg", "message", "text"])?.replacingOccurrences(of: "_", with: " ")
            ?? messageAfterMarker(in: line)
            ?? line

        return WeakSignalFrame(
            timestamp: timestamp,
            mode: mode,
            frequencyHz: doubleField(fields, ["freq", "frequency", "frequencyhz", "rf"]),
            audioFrequencyHz: doubleField(fields, ["audio", "audiohz", "offset", "freqoffset"]),
            snrDB: intField(fields, ["snr", "db"]),
            timeOffsetSec: doubleField(fields, ["dt", "timeoffset"]),
            driftHzPerMinute: doubleField(fields, ["drift"]),
            callsign: first(fields, ["call", "callsign", "txcall"]),
            grid: first(fields, ["grid", "locator"]),
            dxCallsign: first(fields, ["dx", "dxcall", "rxcall"]),
            report: first(fields, ["report", "rpt"]),
            powerDBm: intField(fields, ["power", "dbm"]),
            message: message,
            rawLine: line
        )
    }

    private static func parseWSJTXLine(_ line: String, timestamp: Date) -> WeakSignalFrame? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let modeIndex = parts.firstIndex(where: { mode(from: $0) != nil }),
              let mode = mode(from: parts[modeIndex]) else {
            return nil
        }

        let snr = parts.indices.contains(1) ? Int(parts[1]) : nil
        let dt = parts.indices.contains(2) ? Double(parts[2]) : nil
        let audio = parts.indices.contains(3) ? Double(parts[3]) : nil
        let messageParts = parts.dropFirst(modeIndex + 1)
        let message = messageParts.joined(separator: " ")
        guard !message.isEmpty else { return nil }

        let calls = messageParts.filter { looksLikeCallsign($0) }
        let grids = messageParts.filter { looksLikeGrid($0) }
        let reports = messageParts.filter { looksLikeReport($0) }

        return WeakSignalFrame(
            timestamp: timestamp,
            mode: mode,
            audioFrequencyHz: audio,
            snrDB: snr,
            timeOffsetSec: dt,
            callsign: calls.first,
            grid: grids.first,
            dxCallsign: calls.dropFirst().first,
            report: reports.first,
            powerDBm: mode == .wspr ? messageParts.compactMap(Int.init).last : nil,
            message: message,
            rawLine: line
        )
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

    private static func mode(from value: String) -> WeakSignalMode? {
        let upper = value.uppercased()
        if upper.contains("WSPR") { return .wspr }
        if upper.contains("FT4") { return .ft4 }
        if upper.contains("FT8") { return .ft8 }
        return nil
    }

    private static func first(_ fields: [String: String], _ keys: [String]) -> String? {
        keys.lazy.map(normalizeKey).compactMap { fields[$0] }.first
    }

    private static func intField(_ fields: [String: String], _ keys: [String]) -> Int? {
        guard let value = first(fields, keys) else { return nil }
        return Int(value)
    }

    private static func doubleField(_ fields: [String: String], _ keys: [String]) -> Double? {
        guard let value = first(fields, keys) else { return nil }
        return Double(value)
    }

    private static func messageAfterMarker(in line: String) -> String? {
        for marker in ["message:", "text:"] {
            if let range = line.range(of: marker, options: [.caseInsensitive]) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func looksLikeCallsign(_ value: String) -> Bool {
        let upper = value.uppercased()
        guard upper.count >= 3, upper.count <= 10 else { return false }
        guard upper.contains(where: \.isNumber), upper.contains(where: \.isLetter) else { return false }
        return upper.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" }
    }

    private static func looksLikeGrid(_ value: String) -> Bool {
        let upper = value.uppercased()
        guard upper.count == 4 || upper.count == 6 else { return false }
        let chars = Array(upper)
        return chars[0].isLetter && chars[1].isLetter && chars[2].isNumber && chars[3].isNumber
    }

    private static func looksLikeReport(_ value: String) -> Bool {
        if value.hasPrefix("+") || value.hasPrefix("-") {
            return Int(value) != nil
        }
        return value.uppercased().hasPrefix("R-") || value.uppercased().hasPrefix("R+")
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

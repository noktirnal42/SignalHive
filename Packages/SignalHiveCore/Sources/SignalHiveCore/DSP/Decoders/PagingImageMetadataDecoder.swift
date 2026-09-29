import Foundation

public enum PagingImageMode: String, Sendable, Codable, CaseIterable {
    case pocsag = "POCSAG"
    case flex = "FLEX"
    case sstv = "SSTV"
}

public struct PagingImageFrame: Identifiable, Sendable, Codable, Hashable {
    public let id = UUID()
    public var timestamp: Date
    public var mode: PagingImageMode
    public var address: String?
    public var capCode: String?
    public var baudRate: Int?
    public var function: String?
    public var imageMode: String?
    public var width: Int?
    public var height: Int?
    public var message: String?
    public var rawLine: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case mode
        case address
        case capCode
        case baudRate
        case function
        case imageMode
        case width
        case height
        case message
        case rawLine
    }

    public init(
        timestamp: Date = .now,
        mode: PagingImageMode,
        address: String? = nil,
        capCode: String? = nil,
        baudRate: Int? = nil,
        function: String? = nil,
        imageMode: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        message: String? = nil,
        rawLine: String
    ) {
        self.timestamp = timestamp
        self.mode = mode
        self.address = address
        self.capCode = capCode
        self.baudRate = baudRate
        self.function = function
        self.imageMode = imageMode
        self.width = width
        self.height = height
        self.message = message
        self.rawLine = rawLine
    }
}

public final class PagingImageMetadataDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "Paging/Image Metadata"
    public let requiredBandwidth: Double = 25_000
    public var timestampProvider: @Sendable () -> Date = { .now }
    public var iqBridge: any DecoderIQBridge

    private var recentFrames: [PagingImageFrame] = []
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
            kind: .pagingImage,
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
                payload: .pagingImage(frame)
            )
        }
    }

    public func allFrames() -> [PagingImageFrame] {
        recentFrames
    }

    public static func parseBridgeOutput(_ text: String, timestamp: Date = .now) -> [PagingImageFrame] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0), timestamp: timestamp) }
    }

    private static func parseLine(_ line: String, timestamp: Date) -> PagingImageFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let mode = detectMode(in: trimmed) else { return nil }
        let fields = keyValueFields(in: trimmed)

        return PagingImageFrame(
            timestamp: timestamp,
            mode: mode,
            address: first(fields, ["address", "addr", "ric"]),
            capCode: first(fields, ["cap", "capcode"]),
            baudRate: intField(fields, ["baud", "rate"]),
            function: first(fields, ["function", "func", "type"]),
            imageMode: first(fields, ["mode", "image", "format"]),
            width: intField(fields, ["width", "w"]),
            height: intField(fields, ["height", "h"]),
            message: message(from: trimmed, fields: fields),
            rawLine: trimmed
        )
    }

    private static func detectMode(in line: String) -> PagingImageMode? {
        let upper = line.uppercased()
        if upper.contains("POCSAG") {
            return .pocsag
        }
        if upper.contains("FLEX") {
            return .flex
        }
        if upper.contains("SSTV") || upper.contains("MARTIN") || upper.contains("SCOTTIE") || upper.contains("ROBOT") {
            return .sstv
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

    private static func message(from line: String, fields: [String: String]) -> String? {
        if let explicit = first(fields, ["msg", "message", "text"]) {
            return explicit.replacingOccurrences(of: "_", with: " ")
        }
        for marker in ["message:", "text:"] {
            if let range = line.range(of: marker, options: [.caseInsensitive]) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func defaultIQBridge() -> any DecoderIQBridge {
        #if os(macOS)
        if let bridge = DecoderToolPresets.pagingImageMultimonNG.makeBridge() {
            return bridge
        }
        #endif
        return UnavailableDecoderIQBridge()
    }
}

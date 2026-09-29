import Foundation

// MARK: - Codeplug models

public enum RadioTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case baofengUV5R = "Baofeng UV-5R"
    case baofengUV82 = "Baofeng UV-82"
    case baofengBFF8HP = "Baofeng BF-F8HP"
    case kenwoodTHD74 = "Kenwood TH-D74"
    case unidenBCD436HP = "Uniden BCD436HP"
    case unidenSDS100 = "Uniden SDS100"
    case genericCHIRPCSV = "Generic (CHIRP CSV)"

    public var id: String { rawValue }

    public var channelCapacity: Int {
        switch self {
        case .baofengUV5R: return 128
        case .baofengUV82: return 128
        case .baofengBFF8HP: return 128
        case .kenwoodTHD74: return 1000
        case .unidenBCD436HP: return 500
        case .unidenSDS100: return 500
        case .genericCHIRPCSV: return 10_000
        }
    }

    public var supportsDirectWrite: Bool {
        switch self {
        case .baofengUV5R, .baofengUV82, .baofengBFF8HP: return true
        case .unidenBCD436HP, .unidenSDS100: return true
        default: return false
        }
    }

    public var supportsNetworkWrite: Bool {
        switch self {
        case .unidenSDS100: return true
        default: return false
        }
    }

    public var icon: String {
        switch self {
        case .baofengUV5R, .baofengUV82, .baofengBFF8HP: return "walkie-talkie"
        case .kenwoodTHD74: return "radio"
        case .unidenBCD436HP, .unidenSDS100: return "scanner"
        case .genericCHIRPCSV: return "doc.badge.arrow.up"
        }
    }
}

public enum ChannelMode: String, Codable, CaseIterable, Sendable {
    case fm = "FM"
    case nfm = "NFM"
    case am = "AM"
    case dmr = "DMR"
    case p25 = "P25"
    case dstar = "D-STAR"
}

public struct CodeplugChannel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var frequencyHz: Double
    public var offsetHz: Double
    public var mode: ChannelMode
    public var ctcssToneHz: Double
    public var dtcsCode: Int
    public var talkgroupID: Int
    public var powerWatts: Int
    public var notes: String
    public var sourceCallSign: String

    public init(
        id: UUID = UUID(),
        name: String,
        frequencyHz: Double,
        offsetHz: Double = 0,
        mode: ChannelMode = .nfm,
        ctcssToneHz: Double = 0,
        dtcsCode: Int = 0,
        talkgroupID: Int = 0,
        powerWatts: Int = 5,
        notes: String = "",
        sourceCallSign: String = ""
    ) {
        self.id = id
        self.name = name
        self.frequencyHz = frequencyHz
        self.offsetHz = offsetHz
        self.mode = mode
        self.ctcssToneHz = ctcssToneHz
        self.dtcsCode = dtcsCode
        self.talkgroupID = talkgroupID
        self.powerWatts = powerWatts
        self.notes = notes
        self.sourceCallSign = sourceCallSign
    }
}

public struct Codeplug: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var target: RadioTarget
    public var channels: [CodeplugChannel]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "My Codeplug",
        target: RadioTarget = .baofengUV5R,
        channels: [CodeplugChannel] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.channels = channels
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isOverCapacity: Bool { channels.count > target.channelCapacity }

    public mutating func add(channel: CodeplugChannel) {
        channels.append(channel)
        updatedAt = Date()
    }

    public mutating func remove(channelID: UUID) {
        channels.removeAll { $0.id == channelID }
        updatedAt = Date()
    }
}

// MARK: - Common CTCSS tones (Baofeng-compatible standard list)

public enum CTCSSCatalog {
    public static let tones: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
        94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
        131.8, 136.5, 141.3, 141.3, 146.2, 151.4, 156.7, 162.2, 167.9, 173.8,
        179.9, 186.2, 192.8, 203.5, 206.5, 218.1, 225.7, 229.1, 233.6, 241.8,
        250.3, 254.1,
    ]
}

// MARK: - Write result

public struct CodeplugWriteResult: Sendable {
    public var channelsWritten: Int
    public var durationSeconds: Double
    public var deviceName: String
    public var errors: [String]

    public init(channelsWritten: Int, durationSeconds: Double, deviceName: String, errors: [String] = []) {
        self.channelsWritten = channelsWritten
        self.durationSeconds = durationSeconds
        self.deviceName = deviceName
        self.errors = errors
    }
}

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

// MARK: - Sub-audible tones

/// The 50 CTCSS tones (Hz) radios of this class offer, as CHIRP lists them.
public enum CTCSSCatalog {
    public static let tones: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
        94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
        131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
        171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
        203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1,
    ]

    public static func isStandard(_ hz: Double) -> Bool {
        tones.contains { abs($0 - hz) < 0.05 }
    }
}

/// The 104 digital-coded-squelch codes (octal numbers written as decimal digits, like 023).
public enum DCSCatalog {
    public static let codes: [Int] = [
        23, 25, 26, 31, 32, 36, 43, 47, 51, 53, 54, 65, 71, 72, 73, 74, 114, 115, 116, 122, 125, 131, 132, 134, 143, 145,
        152, 155, 156, 162, 165, 172, 174, 205, 212, 223, 225, 226, 243, 244, 245, 246, 251, 252, 255, 261, 263, 265, 266,
        271, 274, 306, 311, 315, 325, 331, 332, 343, 346, 351, 356, 364, 365, 371, 411, 412, 413, 423, 431, 432, 445, 446,
        452, 454, 455, 462, 464, 465, 466, 503, 506, 516, 523, 526, 532, 546, 565, 606, 612, 624, 627, 631, 632, 654, 662,
        664, 703, 712, 723, 731, 732, 734, 743, 754,
    ]

    public static func isStandard(_ code: Int) -> Bool { codes.contains(code) }
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

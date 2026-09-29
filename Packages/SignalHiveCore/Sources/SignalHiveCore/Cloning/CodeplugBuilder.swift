import Foundation

// MARK: - Codeplug builder: turn database results into channels

public enum CodeplugBuilder {

    public enum BuildError: Error, LocalizedError {
        case noFrequencies

        public var errorDescription: String? {
            switch self {
            case .noFrequencies: return "No frequencies selected to build channels from"
            }
        }
    }

    /// Suggested repeater offset by band (standard US Amateur/Part 90 splits).
    static func suggestedOffset(for hz: Double) -> Double {
        switch hz {
        case 144_000_000...147_995_000:
            return hz < 146_000_000 ? -600_000 : 600_000
        case 222_000_000...224_980_000:
            return -1_600_000
        case 440_000_000...449_995_000:
            return 5_000_000
        case 902_000_000...927_995_000:
            return -12_000_000
        default:
            return 0
        }
    }

    /// Build channels from a set of database frequencies.
    public static func build(
        from frequencies: [(frequencyHz: Double, callSign: String, name: String?)],
        target: RadioTarget,
        namingPolicy: NamingPolicy = .agencyOrCallSign
    ) -> [CodeplugChannel] {
        var channels: [CodeplugChannel] = []
        for (index, item) in frequencies.enumerated() {
            guard index < target.channelCapacity else { break }

            let name: String
            switch namingPolicy {
            case .agencyOrCallSign:
                name = (item.name?.isEmpty == false ? item.name! : item.callSign)
            case .callSignOnly:
                name = item.callSign
            case .numbered:
                name = "CH\(index + 1)"
            }

            let mode: ChannelMode
            switch item.frequencyHz {
            case 118_000_000...136_975_000: mode = .am
            case 0..<30_000_000: mode = .fm
            default: mode = .nfm
            }

            channels.append(CodeplugChannel(
                name: String(name.prefix(7)),
                frequencyHz: item.frequencyHz,
                offsetHz: 0,
                mode: mode,
                notes: item.name ?? "",
                sourceCallSign: item.callSign
            ))
        }
        return channels
    }

    public enum NamingPolicy: String, Codable, CaseIterable, Sendable {
        case agencyOrCallSign = "Agency or call sign"
        case callSignOnly = "Call sign only"
        case numbered = "Numbered"

        public var id: String { rawValue }
    }
}

import Foundation

// MARK: - Emission designators → mode hints
//
// ITU emission designators look like "20K0F3E": necessary bandwidth (20.0 kHz), then
// modulation (F), signal nature (3 = analog), information type (E = telephony).

public enum ModeHint: String, Codable, CaseIterable, Sendable, Comparable {
    case analogFM
    case am
    case ssb
    case digitalP25
    case digitalOther
    case unknown

    public static func < (lhs: ModeHint, rhs: ModeHint) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    /// Short label for chips and rows.
    public var displayName: String {
        switch self {
        case .analogFM: return "FM"
        case .am: return "AM"
        case .ssb: return "SSB"
        case .digitalP25: return "P25"
        case .digitalOther: return "Digital"
        case .unknown: return "Unknown"
        }
    }
}

extension ChannelMode {
    /// Picks the codeplug mode for a frequency from what the FCC emission designators imply.
    /// Airband is always AM; a frequency carrying both analog and P25 is programmed as analog because
    /// every radio can receive it.
    public static func suggested(frequencyHz: Double, hints: [ModeHint], bandwidthHz: Double?) -> ChannelMode {
        if (118_000_000...136_975_000).contains(frequencyHz) { return .am }
        if hints.contains(.digitalP25), !hints.contains(.analogFM) { return .p25 }
        if hints.contains(.analogFM) { return (bandwidthHz ?? 0) > 12_500 ? .fm : .nfm }
        if hints.contains(.am) || hints.contains(.ssb) { return .am }
        return .nfm
    }
}

public struct EmissionInfo: Equatable, Sendable {
    public var bandwidthHz: Double?
    public var modeHint: ModeHint

    public init(bandwidthHz: Double?, modeHint: ModeHint) {
        self.bandwidthHz = bandwidthHz
        self.modeHint = modeHint
    }
}

public enum EmissionDesignator {

    public static func parse(_ code: String) -> EmissionInfo {
        let chars = Array(code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        guard chars.count >= 7 else { return EmissionInfo(bandwidthHz: nil, modeHint: .unknown) }

        let bandwidth = parseBandwidth(chars[0..<4])
        let modulation = chars[4]
        let nature = chars[5]
        let information = chars[6]

        let hint: ModeHint
        if (modulation == "F" || modulation == "G"), (nature == "2" || nature == "3") {
            hint = .analogFM
        } else if modulation == "F", nature == "1", "EDW".contains(information),
                  let bandwidth, (8000...8200).contains(bandwidth) {
            hint = .digitalP25
        } else if "1789".contains(nature) {
            hint = .digitalOther
        } else if modulation == "A" {
            hint = .am
        } else if "HJRB".contains(modulation) {
            hint = .ssb
        } else {
            hint = .unknown
        }
        return EmissionInfo(bandwidthHz: bandwidth, modeHint: hint)
    }

    /// The letter H/K/M/G marks the decimal point and the unit: "20K0" = 20.0 kHz, "8K10" = 8.10 kHz.
    private static func parseBandwidth(_ chars: ArraySlice<Character>) -> Double? {
        let units: [Character: Double] = ["H": 1, "K": 1e3, "M": 1e6, "G": 1e9]
        guard let unitIndex = chars.firstIndex(where: { units[$0] != nil }),
              unitIndex > chars.startIndex else { return nil }
        let before = String(chars[chars.startIndex..<unitIndex])
        let after = String(chars[chars.index(after: unitIndex)...])
        guard let mantissa = Int(before + after),
              before.allSatisfy(\.isNumber), after.allSatisfy(\.isNumber) else { return nil }
        let scale = pow(10.0, Double(after.count))
        return Double(mantissa) * units[chars[unitIndex]]! / scale
    }
}

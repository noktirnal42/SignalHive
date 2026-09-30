import Foundation

/// What each supported radio can hold. The frequency ranges are the bands the manufacturers document, rounded; they are
/// used to warn about channels a radio probably cannot use, never to refuse them.
extension RadioTarget {
    /// Characters the radio can show for a channel name.
    public var maxNameLength: Int {
        switch self {
        case .baofengUV5R, .baofengUV82, .baofengBFF8HP: return 7
        case .kenwoodTHD74, .unidenBCD436HP, .unidenSDS100: return 16
        case .genericCHIRPCSV: return 16
        }
    }

    public var supportedModes: Set<ChannelMode> {
        switch self {
        case .baofengUV5R, .baofengUV82, .baofengBFF8HP: return [.fm, .nfm]
        case .kenwoodTHD74: return [.fm, .nfm, .am, .dstar]
        case .unidenBCD436HP, .unidenSDS100: return [.fm, .nfm, .am, .p25, .dmr]
        case .genericCHIRPCSV: return Set(ChannelMode.allCases)
        }
    }

    /// Frequencies the radio covers, in hertz.
    public var frequencyRanges: [ClosedRange<Double>] {
        switch self {
        case .baofengUV5R, .baofengUV82, .baofengBFF8HP:
            return [136_000_000...174_000_000, 400_000_000...520_000_000]
        case .kenwoodTHD74:
            return [100_000...524_000_000]
        case .unidenBCD436HP:
            return [25_000_000...512_000_000, 764_000_000...824_000_000, 849_000_000...869_000_000,
                    894_000_000...960_000_000, 1_240_000_000...1_300_000_000]
        case .unidenSDS100:
            return [25_000_000...512_000_000, 758_000_000...824_000_000, 849_000_000...869_000_000,
                    894_000_000...1_000_000_000, 1_240_000_000...1_300_000_000]
        case .genericCHIRPCSV:
            return [1_000...6_000_000_000]
        }
    }

    /// Scanners only listen.
    public var isReceiveOnly: Bool {
        switch self {
        case .unidenBCD436HP, .unidenSDS100: return true
        default: return false
        }
    }

    /// Whether channels can be talkgroups (with no frequency of their own) on a trunked system.
    public var supportsTalkgroups: Bool {
        switch self {
        case .unidenBCD436HP, .unidenSDS100: return true
        default: return false
        }
    }

    public func covers(_ hz: Double) -> Bool {
        frequencyRanges.contains { $0.contains(hz) }
    }
}

/// Names for the parts of the spectrum a scanner user cares about.
public enum RadioBand {
    private static let bands: [(ClosedRange<Double>, String)] = [
        (118_000_000...137_000_000, "Airband"),
        (144_000_000...148_000_000, "2 m ham"),
        (156_000_000...162_025_000, "Marine VHF"),
        (162_400_000...162_550_000, "NOAA weather"),
        (137_000_000...174_000_000, "VHF"),
        (216_000_000...225_000_000, "1.25 m ham"),
        (420_000_000...450_000_000, "70 cm ham"),
        (462_000_000...467_725_000, "FRS / GMRS"),
        (450_000_000...470_000_000, "UHF business"),
        (470_000_000...512_000_000, "UHF-T"),
        (764_000_000...776_000_000, "700 MHz"),
        (851_000_000...869_000_000, "800 MHz"),
        (935_000_000...960_000_000, "900 MHz"),
    ]

    /// The most specific name for a frequency (the list is ordered from narrow to wide within a region).
    public static func name(for hz: Double) -> String {
        if hz <= 0 { return "No frequency" }
        if hz < 30_000_000 { return "HF" }
        if hz < 118_000_000 { return "VHF low" }
        return bands.first { $0.0.contains(hz) }?.1 ?? "Other"
    }
}

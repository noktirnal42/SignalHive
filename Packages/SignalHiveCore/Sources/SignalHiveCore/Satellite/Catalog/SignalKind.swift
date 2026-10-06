import Foundation

/// What a transmission is, in terms of what SignalHive could do with it.
public enum SignalKind: String, Sendable, Codable {
    case lrpt, fmVoice, sstv, aprs, cwBeacon, bpskTelemetry, other, unknown

    /// SatNOGS gives a free-text mode ("LRPT", "FM", "BPSK PMT-A3", "FSK AX.25 G3RUH", ...) and a baud rate.
    public init(satnogsMode: String?, baud: Double?) {
        let mode = satnogsMode?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        switch mode {
        case "", "UNKNOWN": self = .unknown
        case "LRPT": self = .lrpt
        case "FM", "FMN": self = .fmVoice
        case "SSTV": self = .sstv
        case "CW": self = .cwBeacon
        case "AFSK" where baud == 1200: self = .aprs
        default: self = mode.hasPrefix("BPSK") ? .bpskTelemetry : .other
        }
    }

    /// Whether SignalHive can decode this kind. Nothing is `.ready` yet: no decoder is connected to a satellite
    /// recorder (that is a later phase), and the screen must not say otherwise.
    public var decoderStatus: DecoderStatus {
        switch self {
        case .lrpt, .fmVoice, .sstv, .aprs, .cwBeacon: return .planned
        case .bpskTelemetry, .other, .unknown: return .none
        }
    }
}

public enum DecoderStatus: Sendable, Equatable {
    case ready
    case planned
    case none

    /// Lower is better, for choosing a satellite's primary transmitter.
    var rank: Int {
        switch self {
        case .ready: return 0
        case .planned: return 1
        case .none: return 2
        }
    }
}

public enum SignalStrengthClass: String, Sendable, Codable {
    case strong, medium, weak, unknown
}

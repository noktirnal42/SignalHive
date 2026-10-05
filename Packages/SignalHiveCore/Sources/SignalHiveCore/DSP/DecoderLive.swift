import Foundation

// MARK: - Live decoder presets
//
// What the Decoder Hub tunes to when you press Start: a channel, how wide to listen, and the sample rate the decoder wants.
// The dongle samples about a megahertz; `DecoderSession` mixes the channel down to the decoder's rate, so the dongle is
// tuned a little off the channel (away from its DC spike) rather than on it.

public enum LiveDecoderKind: String, CaseIterable, Identifiable, Sendable {
    case acars
    case ais
    case morse

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .acars: return "ACARS"
        case .ais: return "AIS"
        case .morse: return "Morse / CW"
        }
    }

    /// What to expect, said plainly: these decoders are first-pass and none has decoded a signal off the air yet.
    public var caveat: String {
        switch self {
        case .acars:
            return "First-pass decoder written for FM-style MSK captures. Real ACARS is AM-modulated, so on-air decoding is unproven and may produce nothing."
        case .ais:
            return "First-pass GMSK decoder (FM discriminator, 9600 baud, HDLC). Not yet checked against a live ship signal. Needs a marine VHF antenna and a harbor or coast nearby."
        case .morse:
            return "Decodes on-off keyed carriers from the signal's envelope. Needs a clean, steady CW signal; there is no set frequency, so these are calling channels."
        }
    }
}

public struct DecoderLivePreset: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: LiveDecoderKind
    public var name: String
    public var frequencyHz: Double
    public var channelBandwidthHz: Double
    /// The rate the decoder is fed after channelizing, before rounding to a whole decimation.
    public var decoderSampleRateHz: Double
    public var region: String

    public var frequencyMHz: Double { frequencyHz / 1_000_000 }

    /// The dongle's own sample rate and how far below the channel it is tuned.
    public static let deviceSampleRateHz = 1_024_000.0
    public static let tuningOffsetHz = 100_000.0

    /// The session settings for this preset. The tuner sits `tuningOffsetHz` below the channel, which the channelizer
    /// shifts back to zero, so the dongle's DC spike stays out of the signal.
    public func sessionConfig(gainDB: Double) -> DecoderSessionConfig {
        DecoderSessionConfig(
            centerFrequencyHz: frequencyHz - Self.tuningOffsetHz,
            sampleRateHz: Self.deviceSampleRateHz,
            gainDB: gainDB,
            channelOffsetHz: Self.tuningOffsetHz,
            channelBandwidthHz: channelBandwidthHz,
            targetSampleRateHz: decoderSampleRateHz,
            channelizerEnabled: true)
    }

    public func makeDecoder() -> any SignalDecoder {
        switch kind {
        case .acars: return ACARSDecoder()
        case .ais: return AISDecoder()
        case .morse: return MorseDecoder()
        }
    }

    /// Whether a device can tune the preset's channel (the tuner sits a little below it).
    public func isTunable(by range: ClosedRange<Double>) -> Bool {
        range.contains(frequencyHz - Self.tuningOffsetHz) && range.contains(frequencyHz + Self.deviceSampleRateHz / 2)
    }

    public static let all: [DecoderLivePreset] = [
        DecoderLivePreset(id: "acars-131550", kind: .acars, name: "ACARS primary", frequencyHz: 131_550_000,
                          channelBandwidthHz: 25_000, decoderSampleRateHz: 24_000, region: "Worldwide primary"),
        DecoderLivePreset(id: "acars-130025", kind: .acars, name: "ACARS 130.025", frequencyHz: 130_025_000,
                          channelBandwidthHz: 25_000, decoderSampleRateHz: 24_000, region: "North America"),
        DecoderLivePreset(id: "acars-130425", kind: .acars, name: "ACARS 130.425", frequencyHz: 130_425_000,
                          channelBandwidthHz: 25_000, decoderSampleRateHz: 24_000, region: "North America"),
        DecoderLivePreset(id: "acars-129125", kind: .acars, name: "ACARS 129.125", frequencyHz: 129_125_000,
                          channelBandwidthHz: 25_000, decoderSampleRateHz: 24_000, region: "North America"),
        DecoderLivePreset(id: "acars-131725", kind: .acars, name: "ACARS 131.725", frequencyHz: 131_725_000,
                          channelBandwidthHz: 25_000, decoderSampleRateHz: 24_000, region: "Europe"),
        DecoderLivePreset(id: "ais-161975", kind: .ais, name: "AIS 1 (87B)", frequencyHz: 161_975_000,
                          channelBandwidthHz: 25_000, decoderSampleRateHz: 48_000, region: "Worldwide"),
        DecoderLivePreset(id: "ais-162025", kind: .ais, name: "AIS 2 (88B)", frequencyHz: 162_025_000,
                          channelBandwidthHz: 25_000, decoderSampleRateHz: 48_000, region: "Worldwide"),
        DecoderLivePreset(id: "morse-144050", kind: .morse, name: "2 m CW calling", frequencyHz: 144_050_000,
                          channelBandwidthHz: 1_000, decoderSampleRateHz: 8_000, region: "Amateur, Americas"),
        DecoderLivePreset(id: "morse-50090", kind: .morse, name: "6 m CW calling", frequencyHz: 50_090_000,
                          channelBandwidthHz: 1_000, decoderSampleRateHz: 8_000, region: "Amateur, Americas"),
    ]

    public static func presets(for kind: LiveDecoderKind) -> [DecoderLivePreset] {
        all.filter { $0.kind == kind }
    }
}

// MARK: - Live message rows

extension DecoderWorkbench {
    /// A message from a running session, in the same shape the manual tools produce, so one table shows both.
    public static func liveRow(for message: DecodedMessage) -> DecoderWorkbenchMessage {
        let id = message.id.uuidString
        let time = message.timestamp.formatted(.iso8601.time(includingFractionalSeconds: false))
        switch message.payload {
        case .acars(let acars):
            var details = ["Label \(acars.label)", acars.kind.displayName]
            if let registration = acars.registration { details.append("Registration \(registration)") }
            if let flight = acars.flightId { details.append("Flight \(flight)") }
            details.append(time)
            return DecoderWorkbenchMessage(id: id, decoder: "ACARS", title: acars.flightId ?? acars.registration ?? acars.kind.displayName,
                                           summary: acars.text, details: details, raw: acars.text)
        case .ais(let ais):
            let row = aisSummary(ais, raw: "AIS type \(ais.messageType) from MMSI \(ais.mmsi)", index: 0)
            return DecoderWorkbenchMessage(id: id, decoder: row.decoder, title: row.title, summary: row.summary,
                                           details: row.details + [time], raw: row.raw)
        case .morse(let morse):
            return DecoderWorkbenchMessage(
                id: id, decoder: "Morse", title: "CW text", summary: morse.text,
                details: [String(format: "%.0f WPM", morse.wordsPerMinute), "\(Int((morse.confidence * 100).rounded()))% confidence", time],
                raw: morse.text)
        case .text(let text):
            return DecoderWorkbenchMessage(id: id, decoder: message.mode, title: "Text", summary: text, details: [time], raw: text)
        default:
            return DecoderWorkbenchMessage(id: id, decoder: message.mode, title: "\(message.mode) message",
                                           summary: "Decoded, but the hub does not summarize this kind of message yet.",
                                           details: [time], raw: "")
        }
    }
}

import Testing
import Foundation
@testable import SignalHiveCore

struct DecoderLivePresetTests {
    private let rtlRange: ClosedRange<Double> = 24_000_000...1_766_000_000

    @Test func everyKindHasPresetsAndIdentifiersAreUnique() {
        let ids = DecoderLivePreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for kind in LiveDecoderKind.allCases {
            #expect(!DecoderLivePreset.presets(for: kind).isEmpty, "\(kind.title) has no preset")
            #expect(!kind.caveat.isEmpty && !kind.title.isEmpty)
        }
        #expect(DecoderLivePreset.presets(for: .ais).map(\.frequencyHz) == [161_975_000, 162_025_000])
        #expect(DecoderLivePreset.presets(for: .acars).contains { $0.frequencyHz == 131_550_000 })
    }

    @Test func everyPresetIsInsideTheRTLSDRRange() {
        for preset in DecoderLivePreset.all {
            #expect(preset.isTunable(by: rtlRange), "\(preset.name) is outside 24 MHz to 1.766 GHz")
        }
        #expect(!DecoderLivePreset.all[0].isTunable(by: 200_000_000...300_000_000))
    }

    @Test func theTunerSitsBelowTheChannelAndTheChannelizerShiftsItBack() {
        let preset = DecoderLivePreset.presets(for: .ais)[0]
        let config = preset.sessionConfig(gainDB: 38)
        #expect(config.centerFrequencyHz == 161_875_000)
        #expect(config.channelOffsetHz == 100_000)
        #expect(config.centerFrequencyHz + config.channelOffsetHz == preset.frequencyHz)
        #expect(config.sampleRateHz == 1_024_000 && config.gainDB == 38)
        #expect(config.channelizerEnabled)
        #expect(config.channelBandwidthHz == 25_000)
    }

    @Test func eachDecoderGetsAtLeastTheRateItNeeds() async {
        let minimums: [LiveDecoderKind: Double] = [.acars: 4_800, .ais: 9_600, .morse: 1_000]
        for preset in DecoderLivePreset.all {
            let session = DecoderSession(decoder: preset.makeDecoder(), config: preset.sessionConfig(gainDB: 30))
            let snapshot = await session.snapshot
            #expect(snapshot.decoderSampleRateHz >= minimums[preset.kind]!, "\(preset.name): \(snapshot.decoderSampleRateHz) Hz")
            #expect(snapshot.tunedFrequencyHz == preset.frequencyHz, "\(preset.name) is tuned to the wrong frequency")
        }
    }

    @Test func presetsMakeTheRightDecoder() {
        #expect(DecoderLivePreset.presets(for: .acars)[0].makeDecoder().identifier == "ACARS")
        #expect(DecoderLivePreset.presets(for: .ais)[0].makeDecoder().identifier == "AIS")
        #expect(DecoderLivePreset.presets(for: .morse)[0].makeDecoder().identifier == "Morse")
    }

    /// The whole live path with no hardware: a keyed carrier 100 kHz above the tuner, as the 2 m CW preset sets it up, at the
    /// dongle's sample rate, through the channelizer and the Morse decoder.
    @Test func aKeyedCarrierAtTheChannelIsDecodedThroughThePresetChain() async throws {
        let preset = try #require(DecoderLivePreset.all.first { $0.id == "morse-144050" })
        let session = DecoderSession(decoder: preset.makeDecoder(), config: preset.sessionConfig(gainDB: 30))
        let iq = MorseCodec.encodeIQ(text: "SOS", sampleRate: DecoderLivePreset.deviceSampleRateHz, wordsPerMinute: 24,
                                     toneHz: DecoderLivePreset.tuningOffsetHz)
        var heard: [DecodedMessage] = []
        for start in stride(from: 0, to: iq.count, by: 65_536) {
            heard += await session.ingest(samples: Array(iq[start..<min(iq.count, start + 65_536)]))
        }
        let message = try #require(heard.first, "nothing was decoded")
        guard case .morse(let morse) = message.payload else { Issue.record("expected Morse"); return }
        #expect(morse.text == "SOS")
        let snapshot = await session.snapshot
        #expect(snapshot.tunedFrequencyHz == 144_050_000)
    }

    @Test func aCarrierOutsideTheChannelIsNotDecoded() async throws {
        let preset = try #require(DecoderLivePreset.all.first { $0.id == "morse-144050" })
        let session = DecoderSession(decoder: preset.makeDecoder(), config: preset.sessionConfig(gainDB: 30))
        // 20 kHz away from the channel: outside the 1 kHz filter.
        let iq = MorseCodec.encodeIQ(text: "SOS", sampleRate: DecoderLivePreset.deviceSampleRateHz, wordsPerMinute: 24,
                                     toneHz: DecoderLivePreset.tuningOffsetHz + 20_000)
        var heard: [DecodedMessage] = []
        for start in stride(from: 0, to: iq.count, by: 65_536) {
            heard += await session.ingest(samples: Array(iq[start..<min(iq.count, start + 65_536)]))
        }
        #expect(heard.isEmpty)
    }
}

struct LiveRowTests {
    private let when = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func anACARSMessageBecomesARowNamedByItsFlight() {
        let acars = ACARSMessage(timestamp: when, label: "Q0", text: "POS 37.62 -122.38", flightId: "DAL123", registration: "N123AB", kind: .position)
        let row = DecoderWorkbench.liveRow(for: DecodedMessage(timestamp: when, frequency: 131_550_000, mode: "ACARS", payload: .acars(acars)))
        #expect(row.decoder == "ACARS" && row.title == "DAL123" && row.summary == "POS 37.62 -122.38")
        #expect(row.details.contains("Label Q0") && row.details.contains("Position") && row.details.contains("Registration N123AB"))
        #expect(row.status == .decoded)
    }

    @Test func anACARSMessageWithNoFlightIsNamedByItsKind() {
        let acars = ACARSMessage(timestamp: when, label: "H1", text: "WX REQUEST", kind: .weather)
        let row = DecoderWorkbench.liveRow(for: DecodedMessage(timestamp: when, frequency: 0, mode: "ACARS", payload: .acars(acars)))
        #expect(row.title == "Weather")
    }

    @Test func anAISMessageBecomesAVesselRow() {
        let ais = AISMessage(timestamp: when, mmsi: 366_123_456, messageType: 14, payload: .safetyMessage("TEST SAFETY BROADCAST"))
        let row = DecoderWorkbench.liveRow(for: DecodedMessage(timestamp: when, frequency: 162_025_000, mode: "AIS", payload: .ais(ais)))
        #expect(row.decoder == "AIS" && row.title == "Safety message" && row.summary == "TEST SAFETY BROADCAST")
        #expect(row.details.contains("MMSI 366123456") && row.details.contains("Type 14"))
    }

    @Test func aMorseMessageShowsTextSpeedAndConfidence() {
        let morse = MorseMessage(timestamp: when, text: "CQ CQ", wordsPerMinute: 18.4, confidence: 0.93)
        let row = DecoderWorkbench.liveRow(for: DecodedMessage(timestamp: when, frequency: 0, mode: "Morse", payload: .morse(morse)))
        #expect(row.summary == "CQ CQ")
        #expect(row.details.contains("18 WPM") && row.details.contains("93% confidence"))
    }

    @Test func textAndUnknownPayloadsStillMakeARow() {
        let text = DecoderWorkbench.liveRow(for: DecodedMessage(timestamp: when, frequency: 0, mode: "Test", payload: .text("hello")))
        #expect(text.summary == "hello")
        let other = DecoderWorkbench.liveRow(for: DecodedMessage(timestamp: when, frequency: 0, mode: "Odd", payload: .raw(Data([1, 2]))))
        #expect(other.decoder == "Odd" && other.summary.contains("does not summarize"))
    }

    @Test func eachRowHasItsOwnIdentity() {
        let message = DecodedMessage(timestamp: when, frequency: 0, mode: "Test", payload: .text("a"))
        let again = DecodedMessage(timestamp: when, frequency: 0, mode: "Test", payload: .text("a"))
        #expect(DecoderWorkbench.liveRow(for: message).id != DecoderWorkbench.liveRow(for: again).id)
        #expect(DecoderWorkbench.liveRow(for: message).id == DecoderWorkbench.liveRow(for: message).id, "the same message keeps its id")
    }
}

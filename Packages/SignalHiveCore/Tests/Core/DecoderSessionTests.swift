import Testing
import Foundation
@testable import SignalHiveCore

private final class OneShotTextDecoder: SignalDecoder, @unchecked Sendable {
    let identifier = "OneShot"
    let requiredBandwidth = 12_500.0
    var timestampProvider: @Sendable () -> Date = { .now }
    private let lock = NSLock()
    private var emitted = false
    private var sampleRates: [Double] = []

    func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        lock.lock()
        sampleRates.append(sampleRate)
        let shouldEmit = !emitted && !iq.isEmpty
        emitted = true
        lock.unlock()
        guard shouldEmit else { return [] }
        return [
            DecodedMessage(
                timestamp: timestampProvider(),
                frequency: 0,
                mode: identifier,
                payload: .text("decoded \(iq.count) samples")
            )
        ]
    }

    func reset() {
        lock.lock()
        emitted = false
        sampleRates.removeAll()
        lock.unlock()
    }

    var lastSampleRate: Double? {
        lock.lock()
        defer { lock.unlock() }
        return sampleRates.last
    }
}

private final class EveryBlockTextDecoder: SignalDecoder, @unchecked Sendable {
    let identifier = "EveryBlock"
    let requiredBandwidth = 12_500.0
    var timestampProvider: @Sendable () -> Date = { .now }
    private let lock = NSLock()
    private var count = 0

    func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard !iq.isEmpty else { return [] }
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        return [
            DecodedMessage(
                timestamp: timestampProvider(),
                frequency: 0,
                mode: identifier,
                payload: .text("block \(current)")
            )
        ]
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

struct DecoderSessionTests {
    @Test func morseSessionDecodesIQAndTracksStats() async throws {
        let session = DecoderSession(
            decoder: MorseDecoder(),
            config: DecoderSessionConfig(sampleRateHz: 48_000, maxRetainedMessages: 10)
        )
        let iq = MorseCodec.encodeIQ(text: "SOS", sampleRate: 48_000, wordsPerMinute: 24)
        var decoded: [DecodedMessage] = []

        for start in stride(from: 0, to: iq.count, by: 2_048) {
            let end = min(iq.count, start + 2_048)
            decoded += await session.ingest(samples: Array(iq[start..<end]))
        }

        let message = try #require(decoded.first)
        guard case .morse(let morse) = message.payload else {
            Issue.record("Expected Morse payload")
            return
        }
        #expect(morse.text == "SOS")
        #expect(morse.confidence == 1)

        let snapshot = await session.snapshot
        #expect(snapshot.state == .running)
        #expect(snapshot.decoderIdentifier == "Morse")
        #expect(snapshot.totalBlocks > 1)
        #expect(snapshot.totalSamples == iq.count)
        #expect(snapshot.retainedMessageCount == 1)
        #expect(snapshot.totalMessageCount == 1)
        #expect(snapshot.lastHeardAt != nil)
    }

    @Test func sessionPublishesDecodedMessagesOnAsyncStream() async throws {
        let session = DecoderSession(decoder: OneShotTextDecoder())
        let stream = await session.messageStream()
        var iterator = stream.makeAsyncIterator()
        let next = Task { await iterator.next() }

        let emitted = await session.ingest(samples: [ComplexFloat(i: 1, q: 0)])
        #expect(emitted.count == 1)

        let output = try #require(await next.value)
        #expect(output.message.mode == "OneShot")
        #expect(output.snapshot.totalMessageCount == 1)
    }

    @Test func channelizedSessionFeedsDecoderAtChannelRate() async throws {
        let decoder = OneShotTextDecoder()
        let session = DecoderSession(
            decoder: decoder,
            config: DecoderSessionConfig(
                sampleRateHz: 192_000,
                channelOffsetHz: 24_000,
                channelBandwidthHz: 12_500,
                targetSampleRateHz: 48_000,
                channelizerEnabled: true
            )
        )

        var samples: [ComplexFloat] = []
        samples.reserveCapacity(65_536)
        for index in 0..<65_536 {
            let phase = 2 * Double.pi * 24_000 * Double(index) / 192_000
            samples.append(ComplexFloat(i: Float(cos(phase)), q: Float(sin(phase))))
        }
        let messages = await session.ingest(samples: samples)

        #expect(messages.count == 1)
        let sampleRate = try #require(decoder.lastSampleRate)
        #expect(sampleRate > 40_000)
        #expect(sampleRate < 60_000)
        let snapshot = await session.snapshot
        #expect(snapshot.inputSampleRateHz == 192_000)
        #expect(snapshot.decoderSampleRateHz == sampleRate)
        #expect(snapshot.tunedFrequencyHz == 100_024_000)
    }

    @Test func sessionRetainsOnlyTheConfiguredMessageCount() async {
        let session = DecoderSession(
            decoder: EveryBlockTextDecoder(),
            config: DecoderSessionConfig(maxRetainedMessages: 2)
        )

        _ = await session.ingest(samples: [ComplexFloat(i: 1, q: 0)])
        _ = await session.ingest(samples: [ComplexFloat(i: 1, q: 0)])
        _ = await session.ingest(samples: [ComplexFloat(i: 1, q: 0)])

        let snapshot = await session.snapshot
        #expect(snapshot.retainedMessageCount == 2)
        #expect(snapshot.totalMessageCount == 3)
        let retained = await session.messages
        #expect(retained.count == 2)
        #expect(retained.map(\.mode) == ["EveryBlock", "EveryBlock"])
    }
}

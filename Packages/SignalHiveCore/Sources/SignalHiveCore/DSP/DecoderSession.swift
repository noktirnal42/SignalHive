import Foundation

public enum DecoderSessionState: String, Sendable, Equatable {
    case idle
    case running
    case stopped
    case failed
}

public struct DecoderSessionConfig: Sendable, Equatable {
    public var centerFrequencyHz: Double
    public var sampleRateHz: Double
    public var gainDB: Double
    public var channelOffsetHz: Double
    public var channelBandwidthHz: Double
    public var targetSampleRateHz: Double
    public var channelizerEnabled: Bool
    public var maxRetainedMessages: Int

    public init(
        centerFrequencyHz: Double = 100_000_000,
        sampleRateHz: Double = 48_000,
        gainDB: Double = 30,
        channelOffsetHz: Double = 0,
        channelBandwidthHz: Double = 12_500,
        targetSampleRateHz: Double = 48_000,
        channelizerEnabled: Bool = false,
        maxRetainedMessages: Int = 500
    ) {
        self.centerFrequencyHz = centerFrequencyHz
        self.sampleRateHz = sampleRateHz
        self.gainDB = gainDB
        self.channelOffsetHz = channelOffsetHz
        self.channelBandwidthHz = channelBandwidthHz
        self.targetSampleRateHz = targetSampleRateHz
        self.channelizerEnabled = channelizerEnabled
        self.maxRetainedMessages = max(1, maxRetainedMessages)
    }
}

public struct DecoderSessionSnapshot: Sendable, Equatable {
    public let state: DecoderSessionState
    public let decoderIdentifier: String
    public let tunedFrequencyHz: Double
    public let inputSampleRateHz: Double
    public let decoderSampleRateHz: Double
    public let totalBlocks: Int
    public let totalSamples: Int
    public let retainedMessageCount: Int
    public let totalMessageCount: Int
    public let messagesPerMinute: Double
    public let startedAt: Date?
    public let stoppedAt: Date?
    public let lastHeardAt: Date?
    public let lastError: String?
}

public struct DecoderSessionOutput: Identifiable, Sendable {
    public let id = UUID()
    public let message: DecodedMessage
    public let snapshot: DecoderSessionSnapshot

    public init(message: DecodedMessage, snapshot: DecoderSessionSnapshot) {
        self.message = message
        self.snapshot = snapshot
    }
}

/// Runs one decoder against direct or channelized IQ, retaining decoded messages and publishing a stream of outputs.
public actor DecoderSession {
    private let decoder: any SignalDecoder
    private let device: (any SDRDevice)?
    private var config: DecoderSessionConfig
    private var channel: ChannelDownconverter?
    private var decoderSampleRateHz: Double
    private var state: DecoderSessionState = .idle
    private var startedAt: Date?
    private var stoppedAt: Date?
    private var lastHeardAt: Date?
    private var lastError: String?
    private var totalBlocks = 0
    private var totalSamples = 0
    private var totalMessageCount = 0
    private var retainedMessages: [DecodedMessage] = []
    private var continuations: [UUID: AsyncStream<DecoderSessionOutput>.Continuation] = [:]
    private var sampleContinuation: AsyncStream<[ComplexFloat]>.Continuation?
    private var streamTask: Task<Void, Never>?

    public init(decoder: any SignalDecoder, device: (any SDRDevice)? = nil, config: DecoderSessionConfig = .init()) {
        self.decoder = decoder
        self.device = device
        self.config = config
        if config.channelizerEnabled {
            let downconverter = ChannelDownconverter(
                sampleRate: config.sampleRateHz,
                offsetHz: config.channelOffsetHz,
                bandwidthHz: config.channelBandwidthHz,
                targetOutputRate: config.targetSampleRateHz
            )
            self.channel = downconverter
            self.decoderSampleRateHz = downconverter.outputRate
        } else {
            self.channel = nil
            self.decoderSampleRateHz = config.sampleRateHz
        }
    }

    deinit {
        for continuation in continuations.values {
            continuation.finish()
        }
        sampleContinuation?.finish()
        streamTask?.cancel()
    }

    public func configure(_ newConfig: DecoderSessionConfig) {
        config = newConfig
        rebuildChannel()
        resetCounters(keepingState: state)
        decoder.reset()
    }

    public func messageStream() -> AsyncStream<DecoderSessionOutput> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start() async throws {
        guard state != .running else { return }
        guard let device else {
            state = .running
            startedAt = Date()
            stoppedAt = nil
            lastError = nil
            return
        }

        do {
            try await device.open()
            try await device.configure(
                frequency: config.centerFrequencyHz,
                sampleRate: config.sampleRateHz,
                gain: config.gainDB
            )

            let (stream, continuation) = AsyncStream<[ComplexFloat]>.makeStream()
            sampleContinuation = continuation
            try await device.startStreaming { buffer, _ in
                continuation.yield([ComplexFloat](rtlRaw: buffer))
            }
            streamTask = Task { [weak self] in
                guard let self else { return }
                for await samples in stream {
                    await self.ingest(samples: samples)
                }
            }
            state = .running
            startedAt = Date()
            stoppedAt = nil
            lastError = nil
        } catch {
            state = .failed
            lastError = error.localizedDescription
            throw error
        }
    }

    public func stop() async {
        streamTask?.cancel()
        streamTask = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
        if let device {
            await device.stopStreaming()
            await device.close()
        }
        state = .stopped
        stoppedAt = Date()
    }

    @discardableResult
    public func ingest(samples: [ComplexFloat]) -> [DecodedMessage] {
        guard !samples.isEmpty else { return [] }
        if state == .idle || state == .stopped {
            state = .running
            startedAt = Date()
            stoppedAt = nil
        }

        totalBlocks += 1
        totalSamples += samples.count

        let decoderSamples: [ComplexFloat]
        if let channel {
            decoderSamples = channel.process(samples)
        } else {
            decoderSamples = samples
        }
        guard !decoderSamples.isEmpty else { return [] }

        let messages = decoder.process(iq: decoderSamples, sampleRate: decoderSampleRateHz)
        guard !messages.isEmpty else { return [] }

        lastHeardAt = messages.last?.timestamp ?? Date()
        totalMessageCount += messages.count
        retainedMessages.append(contentsOf: messages)
        trimRetainedMessages()

        let snapshot = self.snapshot
        for message in messages {
            let output = DecoderSessionOutput(message: message, snapshot: snapshot)
            for continuation in continuations.values {
                continuation.yield(output)
            }
        }
        return messages
    }

    public var snapshot: DecoderSessionSnapshot {
        let elapsed = startedAt.map { max(0.001, Date().timeIntervalSince($0)) } ?? 0.001
        return DecoderSessionSnapshot(
            state: state,
            decoderIdentifier: decoder.identifier,
            tunedFrequencyHz: config.centerFrequencyHz + config.channelOffsetHz,
            inputSampleRateHz: config.sampleRateHz,
            decoderSampleRateHz: decoderSampleRateHz,
            totalBlocks: totalBlocks,
            totalSamples: totalSamples,
            retainedMessageCount: retainedMessages.count,
            totalMessageCount: totalMessageCount,
            messagesPerMinute: Double(totalMessageCount) / elapsed * 60,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            lastHeardAt: lastHeardAt,
            lastError: lastError
        )
    }

    public var messages: [DecodedMessage] {
        retainedMessages
    }

    public func reset() {
        decoder.reset()
        rebuildChannel()
        resetCounters(keepingState: .idle)
    }

    private func rebuildChannel() {
        if config.channelizerEnabled {
            let downconverter = ChannelDownconverter(
                sampleRate: config.sampleRateHz,
                offsetHz: config.channelOffsetHz,
                bandwidthHz: config.channelBandwidthHz,
                targetOutputRate: config.targetSampleRateHz
            )
            channel = downconverter
            decoderSampleRateHz = downconverter.outputRate
        } else {
            channel = nil
            decoderSampleRateHz = config.sampleRateHz
        }
    }

    private func resetCounters(keepingState newState: DecoderSessionState) {
        state = newState
        startedAt = nil
        stoppedAt = nil
        lastHeardAt = nil
        lastError = nil
        totalBlocks = 0
        totalSamples = 0
        totalMessageCount = 0
        retainedMessages.removeAll(keepingCapacity: true)
    }

    private func trimRetainedMessages() {
        let limit = max(1, config.maxRetainedMessages)
        if retainedMessages.count > limit {
            retainedMessages.removeFirst(retainedMessages.count - limit)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

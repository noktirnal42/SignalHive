import Foundation
import Accelerate
import AVFoundation

/// The DSP pipeline actor: receives raw IQ from an SDRDevice, runs FFT,
/// demodulates, decodes, classifies, and feeds results to subscribers.
///
/// Swift 6 strict concurrency: hardware callback → AsyncStream → actor.
public actor DSPPipeline {
    // MARK: - Configuration

    public struct Config: Sendable {
        public var mode: DemodMode = .nfm
        public var frequency: Double = 100_000_000
        public var sampleRate: Double = 2_048_000
        public var gain: Double = 30
        public var fftConfig: FFTProcessor.Config = .init()
        public var squelchDBFS: Float = -80
        public var audioOutputEnabled: Bool = true
        public var volume: AudioVolume = AudioVolume()
        /// The channel to demodulate: its frequency minus the tuner centre (0 = the centre). The tuner keeps
        /// covering the whole band for the spectrum while this picks one signal out of it.
        public var channelOffsetHz: Double = 0
        public var classificationEnabled: Bool = true

        public init() {}
    }

    // MARK: - Published output

    public private(set) var fftSpectrum: [Float] = []
    public private(set) var fftPeakHold: [Float] = []
    public private(set) var signalPowerDBFS: Float = -120
    public private(set) var isSquelchOpen: Bool = false
    public private(set) var isRunning: Bool = false

    // Subscribers for decoded messages
    private var messageSubscribers: [@Sendable (DecodedMessage) -> Void] = []
    // Subscribers for raw IQ samples (recording, mesh, diagnostics)
    private var iqSubscribers: [@Sendable ([ComplexFloat]) -> Void] = []
    // Subscriber for audio samples (for AudioPlayer)
    // Subscriber for FFT updates
    private var fftSubscribers: [@Sendable ([Float], [Float]) -> Void] = []

    // MARK: - Internal state

    private let device: any SDRDevice
    private var config: Config
    private var fftProcessor: FFTProcessor
    private var demodulator: any Demodulator
    private var decoders: [any SignalDecoder] = []
    private var classifier: AutoClassifier?
    private let squelch: Squelch

    private var sampleStreamContinuation: AsyncStream<[ComplexFloat]>.Continuation?
    private var streamTask: Task<Void, Never>?

    // Audio engine
    private var audioPlayer: SDRAudioPlayer?

    // Channel selection: mix the chosen channel to baseband, filter, decimate, then demodulate.
    private var channel: ChannelDownconverter?
    private var audioDecimator: DecimatingFIR?
    private var audioRate: Double = 48_000
    private var audioSubscribers: [@Sendable ([Float], Double) -> Void] = []
    /// Power in the selected channel (what squelch acts on), as opposed to `signalPowerDBFS` for the whole band.
    public private(set) var channelPowerDBFS: Float = -120

    // MARK: - Init

    public init(device: any SDRDevice, config: Config = .init()) {
        self.device = device
        self.config = config
        self.fftProcessor = FFTProcessor(config: config.fftConfig)
        let setup = Self.makeChannel(for: config)
        self.channel = setup.channel
        self.audioDecimator = setup.decimator
        self.audioRate = setup.audioRate
        self.demodulator = setup.demodulator
        self.squelch = Squelch()
        self.squelch.thresholdDBFS = config.squelchDBFS
        self.audioPlayer = nil
    }

    // MARK: - Control

    public func configure(_ newConfig: Config) async throws {
        config = newConfig
        fftProcessor = FFTProcessor(config: newConfig.fftConfig)
        rebuildChannel()
        squelch.thresholdDBFS = newConfig.squelchDBFS
        audioPlayer = newConfig.audioOutputEnabled ? SDRAudioPlayer(sampleRate: audioRate) : nil
        audioPlayer?.setVolume(newConfig.volume.gain)

        try await device.configure(
            frequency: newConfig.frequency,
            sampleRate: newConfig.sampleRate,
            gain: newConfig.gain
        )
    }

    /// Changes the listening volume immediately (no reconfiguration, no gap in the audio).
    public func setVolume(_ volume: AudioVolume) {
        config.volume = volume
        audioPlayer?.setVolume(volume.gain)
    }

    /// Audio taps (recording, decoders, tests): demodulated, squelched audio and its sample rate.
    public func subscribeToAudio(_ handler: @Sendable @escaping ([Float], Double) -> Void) {
        audioSubscribers.append(handler)
    }

    private struct ChannelSetup {
        var channel: ChannelDownconverter?
        var decimator: DecimatingFIR?
        var audioRate: Double
        var demodulator: any Demodulator
    }

    /// The channel down-converter, demodulator and audio decimation for a mode and channel offset.
    private static func makeChannel(for config: Config) -> ChannelSetup {
        guard config.mode != .raw else {
            return ChannelSetup(channel: nil, decimator: nil, audioRate: config.sampleRate,
                                demodulator: DemodulatorFactory.make(mode: config.mode, sampleRate: config.sampleRate))
        }
        let bandwidth: Double
        let target: Double
        switch config.mode {
        case .wfm: (bandwidth, target) = (200_000, 256_000)
        case .usb, .lsb: (bandwidth, target) = (6_000, 48_000)     // keeps the whole sideband
        case .cw: (bandwidth, target) = (2_000, 48_000)
        case .am: (bandwidth, target) = (10_000, 48_000)
        default: (bandwidth, target) = (12_500, 48_000)
        }
        let ddc = ChannelDownconverter(sampleRate: config.sampleRate, offsetHz: config.channelOffsetHz,
                                       bandwidthHz: bandwidth, targetOutputRate: target)
        var rate = ddc.outputRate
        var decimator: DecimatingFIR?
        if config.mode == .wfm {
            // Wide FM leaves the demodulator at ~256 kHz; bring the audio down to ~48 kHz.
            let factor = max(1, Int(rate / 48_000))
            decimator = DecimatingFIR(taps: FIRDesign.lowPass(passbandHz: 15_000, stopbandHz: 19_000, sampleRate: rate),
                                      factor: factor)
            rate /= Double(factor)
        }
        return ChannelSetup(channel: ddc, decimator: decimator, audioRate: rate,
                            demodulator: DemodulatorFactory.make(mode: config.mode, sampleRate: ddc.outputRate))
    }

    private func rebuildChannel() {
        let setup = Self.makeChannel(for: config)
        channel = setup.channel
        audioDecimator = setup.decimator
        audioRate = setup.audioRate
        demodulator = setup.demodulator
    }

    public func attachDecoder(_ decoder: any SignalDecoder) {
        decoders.append(decoder)
    }

    public func removeDecoder(identifier: String) {
        decoders.removeAll { $0.identifier == identifier }
    }

    public func attachClassifier(_ c: AutoClassifier) {
        classifier = c
    }

    // MARK: - Streaming

    public func start() async throws {
        guard !isRunning else { return }

        let (stream, continuation) = AsyncStream<[ComplexFloat]>.makeStream()
        sampleStreamContinuation = continuation

        // Wire device callback → AsyncStream.
        // Capture continuation directly — AsyncStream.Continuation is Sendable,
        // so this avoids accessing the actor-isolated sampleStreamContinuation from
        // a @Sendable device callback.
        try await device.startStreaming { buf, sampleCount in
            let samples = [ComplexFloat](rtlRaw: buf)
            continuation.yield(samples)
        }
        isRunning = true

        // Process stream on this actor
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await samples in stream {
                await self.processSamples(samples)
            }
        }
    }

    public func stop() async {
        guard isRunning || streamTask != nil || sampleStreamContinuation != nil else { return }

        streamTask?.cancel()
        streamTask = nil
        sampleStreamContinuation?.finish()
        sampleStreamContinuation = nil
        await device.stopStreaming()
        fftProcessor.reset()
        isRunning = false
    }

    // MARK: - Subscription

    public func subscribeToMessages(_ handler: @Sendable @escaping (DecodedMessage) -> Void) {
        messageSubscribers.append(handler)
    }

    public func subscribeToIQ(_ handler: @Sendable @escaping ([ComplexFloat]) -> Void) {
        iqSubscribers.append(handler)
    }

    public func subscribeToFFT(_ handler: @Sendable @escaping ([Float], [Float]) -> Void) {
        fftSubscribers.append(handler)
    }

    public var currentConfig: Config { config }

    /// Process one IQ block through the same path as hardware streaming.
    /// Useful for deterministic tests, replay sources, and mesh-delivered IQ frames.
    public func ingest(samples: [ComplexFloat]) async {
        await processSamples(samples)
    }

    // MARK: - Internal processing

    private func processSamples(_ samples: [ComplexFloat]) async {
        guard !samples.isEmpty else { return }

        // FFT
        let (averaged, peakHold) = fftProcessor.process(samples: samples)
        fftSpectrum = averaged
        fftPeakHold = peakHold

        // Signal power
        signalPowerDBFS = samples.rmsDBFS

        for sub in iqSubscribers {
            sub(samples)
        }

        // Notify FFT subscribers
        for sub in fftSubscribers {
            sub(averaged, peakHold)
        }

        // Demodulate the selected channel (not the whole capture)
        var audioSamples: [Float]
        if let channel {
            let baseband = channel.process(samples)
            if !baseband.isEmpty { channelPowerDBFS = baseband.rmsDBFS }
            var audio = demodulator.demodulate(iq: baseband)
            if audioDecimator != nil { audio = audioDecimator!.processReal(audio) }
            isSquelchOpen = channelPowerDBFS > squelch.thresholdDBFS
            audioSamples = squelch.gate(samples: audio, powerDBFS: channelPowerDBFS)
        } else {
            channelPowerDBFS = signalPowerDBFS
            isSquelchOpen = signalPowerDBFS > squelch.thresholdDBFS
            audioSamples = squelch.gate(samples: demodulator.demodulate(iq: samples), powerDBFS: signalPowerDBFS)
        }

        for sub in audioSubscribers where !audioSamples.isEmpty {
            sub(audioSamples, audioRate)
        }

        // Audio output
        if config.audioOutputEnabled, !audioSamples.isEmpty {
            if audioPlayer == nil {
                audioPlayer = SDRAudioPlayer(sampleRate: audioRate)
                audioPlayer?.setVolume(config.volume.gain)
            }
            audioPlayer?.enqueue(audioSamples)
        }

        // Decoders
        for decoder in decoders {
            let messages = decoder.process(iq: samples, sampleRate: config.sampleRate)
            for msg in messages {
                for sub in messageSubscribers { sub(msg) }
            }
        }

        // AI classification (every 16 blocks to avoid overwhelming ANE)
        if config.classificationEnabled, let classifier {
            if samples.count >= 1024 {
                let slice = Array(samples.prefix(1024))
                let result = await classifier.classify(iq: slice)
                for sub in messageSubscribers {
                    sub(DecodedMessage(
                        timestamp: .now,
                        frequency: config.frequency,
                        mode: "AutoClassify",
                        payload: .classification(result)
                    ))
                }
            }
        }
    }
}

// MARK: - DecodedMessage

public struct DecodedMessage: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let frequency: Double
    public let mode: String
    public let payload: DecodedPayload

    public init(timestamp: Date, frequency: Double, mode: String, payload: DecodedPayload) {
        self.timestamp = timestamp
        self.frequency = frequency
        self.mode = mode
        self.payload = payload
    }
}

// MARK: - Decoder message stubs (full decoders implemented separately)

public enum ACARSMessageKind: String, Sendable, Codable, CaseIterable {
    case position
    case weather
    case maintenance
    case clearance
    case arrival
    case departure
    case freeText
    case unknown

    public var displayName: String {
        switch self {
        case .position: return "Position"
        case .weather: return "Weather"
        case .maintenance: return "Maintenance"
        case .clearance: return "Clearance"
        case .arrival: return "Arrival"
        case .departure: return "Departure"
        case .freeText: return "Message"
        case .unknown: return "Unknown"
        }
    }
}

public struct ACARSMessage: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let frequency: Double
    public let label: String
    public let text: String
    public let flightId: String?
    public let registration: String?
    public let kind: ACARSMessageKind

    public init(
        timestamp: Date = .now,
        frequency: Double = 131_550_000,
        label: String,
        text: String,
        flightId: String? = nil,
        registration: String? = nil,
        kind: ACARSMessageKind = .unknown
    ) {
        self.timestamp = timestamp
        self.frequency = frequency
        self.label = label
        self.text = text
        self.flightId = flightId
        self.registration = registration
        self.kind = kind
    }
}

public struct UATFrame: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let frequency: Double
    public let payload: UATPayload

    public init(timestamp: Date = .now, frequency: Double = 978_000_000, payload: UATPayload) {
        self.timestamp = timestamp
        self.frequency = frequency
        self.payload = payload
    }
}

public enum UATPayload: Sendable {
    case aircraft(UATAircraftReport)
    case weather(UATWeatherProduct)
    case unknown(messageType: UInt8, rawPayload: [UInt8])
}

public struct UATAircraftReport: Identifiable, Sendable {
    public let id: Int
    public let address: Int
    public let callsign: String
    public let latitude: Double
    public let longitude: Double
    public let altitudeFt: Int
    public let groundSpeedKts: Int
    public let headingDeg: Double
    public let verticalRateFpm: Int
    public let squawk: Int?
    public let emergencyState: ADSBEmergencyState?
    public let isOnGround: Bool?
    public let surveillanceAlertActive: Bool?
    public let specialPositionIdentificationActive: Bool?

    public init(
        address: Int,
        callsign: String,
        latitude: Double,
        longitude: Double,
        altitudeFt: Int,
        groundSpeedKts: Int,
        headingDeg: Double,
        verticalRateFpm: Int,
        squawk: Int? = nil,
        emergencyState: ADSBEmergencyState? = nil,
        isOnGround: Bool? = nil,
        surveillanceAlertActive: Bool? = nil,
        specialPositionIdentificationActive: Bool? = nil
    ) {
        self.id = address
        self.address = address
        self.callsign = callsign
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeFt = altitudeFt
        self.groundSpeedKts = groundSpeedKts
        self.headingDeg = headingDeg
        self.verticalRateFpm = verticalRateFpm
        self.squawk = squawk
        self.emergencyState = emergencyState
        self.isOnGround = isOnGround
        self.surveillanceAlertActive = surveillanceAlertActive
        self.specialPositionIdentificationActive = specialPositionIdentificationActive
    }
}

public struct UATWeatherProduct: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let productID: Int
    public let station: String
    public let latitude: Double?
    public let longitude: Double?
    public let text: String

    public init(
        timestamp: Date = .now,
        productID: Int,
        station: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        text: String
    ) {
        self.timestamp = timestamp
        self.productID = productID
        self.station = station
        self.latitude = latitude
        self.longitude = longitude
        self.text = text
    }
}

public struct APRSPacket: Sendable {
    public let source: String
    public let destination: String
    public let information: String
    public init(source: String, destination: String, information: String) {
        self.source = source; self.destination = destination; self.information = information
    }
}

public struct RDSGroup: Sendable {
    public let groupType: UInt8
    public let stationName: String?
    public let radioText: String?
    public init(groupType: UInt8, stationName: String? = nil, radioText: String? = nil) {
        self.groupType = groupType; self.stationName = stationName; self.radioText = radioText
    }
}

public struct MorseMessage: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let text: String
    public let wordsPerMinute: Double
    public let confidence: Double

    public init(timestamp: Date = .now, text: String, wordsPerMinute: Double, confidence: Double) {
        self.timestamp = timestamp
        self.text = text
        self.wordsPerMinute = wordsPerMinute
        self.confidence = confidence
    }
}

// MARK: - Decoded Payload

public enum DecodedPayload: Sendable {
    case ais(AISMessage)
    case adsb(ADSBFrame)
    case acars(ACARSMessage)
    case uat(UATFrame)
    case digitalVoice(DigitalVoiceFrame)
    case pagingImage(PagingImageFrame)
    case weakSignal(WeakSignalFrame)
    case classification(ClassificationResult)
    case text(String)
    case aprs(APRSPacket)
    case rds(RDSGroup)
    case morse(MorseMessage)
    case raw(Data)
}

// MARK: - SignalDecoder Protocol

public protocol SignalDecoder: AnyObject, Sendable {
    var identifier: String { get }
    var requiredBandwidth: Double { get }
    var timestampProvider: @Sendable () -> Date { get set }
    func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage]
    func reset()
}

// MARK: - Simple Audio Player

final class SDRAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let outputFormat: AVAudioFormat
    private let inputSampleRate: Double
    private let outputSampleRate: Double = 48_000
    private var buffer: [Float] = []
    private let bufferSize = 4096

    init(sampleRate: Double) {
        self.inputSampleRate = sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 1)!
        self.outputFormat = format

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try? engine.start()
        playerNode.play()
    }

    /// Linear gain 0...1 applied at the mixer, so it affects everything that is playing.
    func setVolume(_ gain: Float) {
        engine.mainMixerNode.outputVolume = max(0, min(1, gain))
    }

    func enqueue(_ samples: [Float]) {
        // Simple linear resample to 48kHz
        let ratio = outputSampleRate / inputSampleRate
        let outCount = Int(Double(samples.count) * ratio)
        var resampled = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) / ratio
            let lo = Int(srcIdx)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(srcIdx - Double(lo))
            resampled[i] = samples[lo] * (1 - frac) + samples[hi] * frac
        }

        guard let buf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(resampled.count)) else { return }
        buf.frameLength = buf.frameCapacity
        if let channelData = buf.floatChannelData?[0] {
            resampled.withUnsafeBufferPointer { ptr in
                channelData.update(from: ptr.baseAddress!, count: resampled.count)
            }
        }
        playerNode.scheduleBuffer(buf)
    }
}

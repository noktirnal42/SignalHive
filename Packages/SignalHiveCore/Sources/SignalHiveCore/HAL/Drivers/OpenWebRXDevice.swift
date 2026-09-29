import Foundation

/// First-pass OpenWebRX WebSocket source.
///
/// The product spec calls for a binary float32 IQ stream plus JSON control
/// messages. This implementation normalizes the endpoint URL, manages a
/// WebSocket session, forwards binary float32 frames into the SDR pipeline,
/// and keeps the control-plane contract testable without live infrastructure.
public final class OpenWebRXDevice: SDRDevice, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .openwebrx
    public let supportsTX = false

    public let frequencyRange: ClosedRange<Double> = 0...6_000_000_000
    public let supportedSampleRates: [Double] = [
        48_000, 96_000, 192_000, 250_000, 500_000, 1_000_000, 2_048_000
    ]
    public let gainRange: ClosedRange<Double> = 0...0

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 250_000
    public private(set) var currentGain: Double = 0

    private let sourceURLString: String
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var isStreaming = false

    public init(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceURLString = trimmed

        if let normalized = try? Self.normalizedWebSocketURL(from: trimmed),
           let host = normalized.host, !host.isEmpty {
            let portSuffix = normalized.port.map { ":\($0)" } ?? ""
            self.name = "OpenWebRX @ \(host)\(portSuffix)"
        } else {
            self.name = "OpenWebRX @ \(trimmed)"
        }

        self.serial = trimmed
        self.id = UUID(
            uuidString: "00000000-0000-0000-0001-" + String(format: "%012X", abs(trimmed.hashValue))
        ) ?? UUID()
    }

    public func open() async throws {
        let url = try Self.normalizedWebSocketURL(from: sourceURLString)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()

        self.session = session
        self.webSocketTask = task
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        guard frequencyRange.contains(frequency) else {
            throw SDRError.configurationFailed("Frequency \(frequency) Hz is outside OpenWebRX range")
        }
        guard supportedSampleRates.contains(sampleRate) else {
            throw SDRError.configurationFailed("Unsupported OpenWebRX sample rate \(sampleRate)")
        }
        guard gainRange.contains(gain) else {
            throw SDRError.configurationFailed("OpenWebRX gain is remote-managed")
        }

        currentFrequency = frequency
        currentSampleRate = sampleRate
        currentGain = gain

        guard let task = webSocketTask else { return }
        try await sendControlMessage(Self.controlMessage(
            frequency: frequency,
            sampleRate: sampleRate,
            gain: gain
        ), over: task)
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        guard let task = webSocketTask else {
            throw SDRError.streamingFailed("OpenWebRX source is not connected")
        }

        isStreaming = true
        let initialMessage = Self.controlMessage(
            frequency: currentFrequency,
            sampleRate: currentSampleRate,
            gain: currentGain
        )
        try await sendControlMessage(initialMessage, over: task)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while self.isStreaming {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .data(let data):
                        guard data.count >= MemoryLayout<Float>.size * 2 else { continue }
                        let sampleCount = data.count / (MemoryLayout<Float>.size * 2)
                        data.withUnsafeBytes { rawBuffer in
                            let buffer = rawBuffer.bindMemory(to: UInt8.self)
                            callback(buffer, sampleCount)
                        }
                    case .string:
                        continue
                    @unknown default:
                        continue
                    }
                } catch {
                    break
                }
            }
        }
    }

    public func stopStreaming() async {
        isStreaming = false
    }

    public func close() async {
        isStreaming = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    static func normalizedWebSocketURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            throw SDRError.networkError("Invalid OpenWebRX URL")
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            throw SDRError.networkError("OpenWebRX URL must use http(s) or ws(s)")
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/ws/"
        }

        guard let url = components.url, url.host != nil else {
            throw SDRError.networkError("Invalid OpenWebRX endpoint")
        }
        return url
    }

    static func controlMessage(frequency: Double, sampleRate: Double, gain: Double) -> String {
        let payload: [String: Any] = [
            "action": "start",
            "center_freq": Int(frequency.rounded()),
            "samp_rate": Int(sampleRate.rounded()),
            "gain": gain
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"action":"start"}"#
        }
        return json
    }

    private func sendControlMessage(_ message: String, over task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(message))
    }
}

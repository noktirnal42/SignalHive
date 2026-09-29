import Foundation
import Network

/// RTL-TCP network client. Connects to an rtl_tcp server at host:port.
///
/// Protocol:
/// - On connect: server sends 12-byte DongleInfo struct
/// - Stream: continuous interleaved uint8 IQ (128=DC, 0=min, 255=max)
/// - Commands: 5-byte packets [cmd(1), value(4, big-endian)]
public final class NetworkSDRDevice: SDRDevice, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let serial: String
    public let deviceType: SDRDeviceType = .network
    public let supportsTX = false

    public let frequencyRange: ClosedRange<Double> = 24_000_000...1_766_000_000
    public let supportedSampleRates: [Double] = [
        250_000, 1_000_000, 1_024_000, 1_800_000, 2_000_000, 2_048_000,
        2_500_000, 3_200_000
    ]
    public let gainRange: ClosedRange<Double> = 0...50

    public private(set) var currentFrequency: Double = 100_000_000
    public private(set) var currentSampleRate: Double = 2_048_000
    public private(set) var currentGain: Double = 30

    private let host: String
    private let port: Int
    private var connection: NWConnection?
    private var isStreaming = false

    public init(host: String, port: Int = 1234) {
        self.host = host
        self.port = port
        self.name = "rtl_tcp @ \(host):\(port)"
        self.serial = "\(host):\(port)"
        self.id = UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012X", abs(("\(host):\(port)").hashValue))) ?? UUID()
    }

    public func open() async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.connection = conn

        return try await withCheckedThrowingContinuation { continuation in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let err):
                    continuation.resume(throwing: SDRError.networkError("Connection failed: \(err)"))
                case .cancelled:
                    continuation.resume(throwing: SDRError.networkError("Connection cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    public func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {
        currentFrequency = frequency
        currentSampleRate = sampleRate
        currentGain = gain

        try await sendCommand(0x01, value: UInt32(frequency))    // SET_FREQ
        try await sendCommand(0x02, value: UInt32(sampleRate))   // SET_SAMPLE_RATE
        try await sendCommand(0x0D, value: gain > 0 ? 1 : 0)    // SET_GAIN_MODE (manual=1)
        try await sendCommand(0x04, value: UInt32(gain * 10))    // SET_GAIN (tenths of dB)
    }

    public func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {
        guard let conn = connection else { throw SDRError.streamingFailed("Not connected") }
        isStreaming = true

        // Read and discard 12-byte DongleInfo header
        _ = try await receiveExact(connection: conn, length: 12)

        // Start reading IQ data in blocks
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let blockSize = 16384
            while self.isStreaming {
                do {
                    let data = try await self.receiveExact(connection: conn, length: blockSize)
                    data.withUnsafeBytes { raw in
                        let buf = raw.bindMemory(to: UInt8.self)
                        callback(buf, blockSize / 2)
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
        connection?.cancel()
        connection = nil
    }

    // MARK: - Private helpers

    private func sendCommand(_ cmd: UInt8, value: UInt32) async throws {
        guard let conn = connection else { return }
        var data = Data(count: 5)
        data[0] = cmd
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { bytes in
            data.replaceSubrange(1..<5, with: bytes)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SDRError.networkError("Send failed: \(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveExact(connection: NWConnection, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: SDRError.networkError("Receive failed: \(error)"))
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: SDRError.networkError("No data received"))
                }
            }
        }
    }
}

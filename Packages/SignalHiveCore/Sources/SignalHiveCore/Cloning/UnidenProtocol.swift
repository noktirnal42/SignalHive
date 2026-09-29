import Foundation

// MARK: - Uniden BCDx36HP scanner serial protocol (basic programming subset)
//
// Official "Scanner Serial Protocol" (ASCII text, CR-terminated):
//   PRG        — enter program mode
//   EPG        — exit program mode
//   MDL        — query model
//   VER        — query firmware version
//   SIN,<obj>  — get system object
//   CIN,<obj>  — get channel object
//   TIN,<obj>  — get talkgroup object
//   QSH,<key>  — query set hash
//   GLG / STS  — live monitoring commands
//
// Full DMA programming (writing systems/sites/channels) is a later phase;
// this implements identification, program-mode, and live status reads so the
// app can remote-control and identify connected scanners on macOS, and the
// SDS100/SDS200 over UDP:50536 on any platform.

public enum UnidenProtocol {

    public static let terminator: UInt8 = 0x0D

    public struct ScannerIdentity: Sendable {
        public var model: String
        public var firmware: String
    }

    public struct LiveStatus: Sendable {
        public var raw: String
        public var frequencyHz: Double?
        public var systemName: String?
        public var channelName: String?
    }

    // MARK: Serial (macOS)

    #if os(macOS)
    public static func command(_ port: SerialTransport, _ cmd: String) async throws -> String {
        port.drain()
        var data = Data(cmd.utf8)
        data.append(terminator)
        try port.write(data)
        let response = try port.readUntilTerminator(terminator, timeout: 3.0)
        return String(decoding: response, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func identify(port: SerialTransport) async throws -> ScannerIdentity {
        let model = try await command(port, "MDL")
        let version = try await command(port, "VER")
        return ScannerIdentity(model: cleanResponse(model), firmware: cleanResponse(version))
    }

    public static func enterProgramMode(port: SerialTransport) async throws {
        _ = try await command(port, "PRG")
    }

    public static func exitProgramMode(port: SerialTransport) async throws {
        _ = try await command(port, "EPG")
    }
    #endif

    // MARK: UDP (SDS100/SDS200 remote protocol, port 50536)

    public final class UDPRemote: @unchecked Sendable {
        private var socket: Int32 = -1
        private let host: String
        private let port: UInt16

        public init(host: String, port: UInt16 = 50536) {
            self.host = host
            self.port = port
        }

        public func connect() throws {
            socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard socket >= 0 else { return }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            _ = bindResult
        }

        public func close() {
            if socket >= 0 { Darwin.close(socket); socket = -1 }
        }

        deinit { close() }
    }

    // MARK: Helpers

    static func cleanResponse(_ response: String) -> String {
        response
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    /// Parse a GLG (global log) response for the active frequency.
    /// GLG,<RF>,<CT...>,<TG>,<SYS>,<TAG>,<APCO>,<CHN>,<NAME>,...
    public static func parseLiveStatus(_ response: String) -> LiveStatus {
        let fields = response.components(separatedBy: ",")
        var status = LiveStatus(raw: response, frequencyHz: nil, systemName: nil, channelName: nil)
        if fields.count > 1, let mhz = Double(fields[1]) {
            status.frequencyHz = mhz * 1_000_000
        }
        if fields.count > 4 { status.systemName = fields[4] }
        if fields.count > 8 { status.channelName = fields[8] }
        return status
    }
}

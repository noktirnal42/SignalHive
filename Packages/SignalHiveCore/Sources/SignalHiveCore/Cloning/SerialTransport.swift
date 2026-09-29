import Foundation

#if os(macOS)
// MARK: - POSIX serial transport (macOS)
// Used for radio programming cables: Baofeng (CP2102/CH340/PL2303 USB-serial),
// Uniden USB serial, etc. Serial devices mount as /dev/cu.usbserial-*.

public enum SerialError: Error, LocalizedError {
    case deviceNotFound
    case openFailed(String)
    case configureFailed(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "No serial device found — connect the programming cable"
        case let .openFailed(path): return "Failed to open serial port \(path)"
        case let .configureFailed(detail): return "Failed to configure serial port: \(detail)"
        case let .ioFailed(detail): return "Serial I/O failed: \(detail)"
        }
    }
}

public final class SerialTransport: @unchecked Sendable {
    private var fd: Int32 = -1
    private let path: String
    private let baudRate: Int

    public static func availableDevices() -> [String] {
        let dir = "/dev"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries
            .filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.usbmodem") }
            .sorted()
            .map { "\(dir)/\($0)" }
    }

    public init(path: String, baudRate: Int = 9600) {
        self.path = path
        self.baudRate = baudRate
    }

    public func open() throws {
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else {
            throw SerialError.openFailed("\(path): errno \(errno)")
        }
        fd = f

        var termios = termios()
        guard tcgetattr(fd, &termios) == 0 else {
            closePort()
            throw SerialError.configureFailed("tcgetattr")
        }

        cfmakeraw(&termios)
        let speed = UInt(baudRate)
        cfsetispeed(&termios, speed)
        cfsetospeed(&termios, speed)

        // VMIN = 0, VTIME = 2 (centiseconds)
        termios.c_cc.16 = 0
        termios.c_cc.17 = 2

        termios.c_cflag |= UInt(CLOCAL | CREAD)
        termios.c_cflag &= ~UInt(CRTSCTS)

        guard tcsetattr(fd, TCSANOW, &termios) == 0 else {
            closePort()
            throw SerialError.configureFailed("tcsetattr")
        }

        var flags = fcntl(fd, F_GETFL)
        flags &= ~Int32(O_NONBLOCK)
        _ = fcntl(fd, F_SETFL, flags)
    }

    public func write(_ data: Data) throws {
        guard fd >= 0 else { throw SerialError.ioFailed("port not open") }
        let written = data.withUnsafeBytes { buf -> Int in
            Darwin.write(fd, buf.baseAddress, buf.count)
        }
        guard written == data.count else {
            throw SerialError.ioFailed("wrote \(written)/\(data.count)")
        }
    }

    public func read(expected: Int, timeout: TimeInterval = 2.0) throws -> Data {
        guard fd >= 0 else { throw SerialError.ioFailed("port not open") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: max(1, expected))
        let deadline = Date().addingTimeInterval(timeout)

        while data.count < expected, Date() < deadline {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
            } else if n < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                throw SerialError.ioFailed("read errno \(errno)")
            }
            if data.count < expected {
                usleep(10_000)
            }
        }
        return data
    }

    public func readUntilTerminator(_ terminator: UInt8 = 0x0D, maxLength: Int = 4096, timeout: TimeInterval = 3.0) throws -> Data {
        guard fd >= 0 else { throw SerialError.ioFailed("port not open") }
        var data = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let n = Darwin.read(fd, &byte, 1)
            if n > 0 {
                data.append(byte)
                if byte == terminator { return data }
                if data.count >= maxLength { return data }
            } else if n < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                throw SerialError.ioFailed("read errno \(errno)")
            }
            usleep(5_000)
        }
        return data
    }

    public func drain() {
        guard fd >= 0 else { return }
        _ = tcflush(fd, TCIFLUSH)
    }

    private func closePort() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    public func close() {
        closePort()
    }

    deinit {
        closePort()
    }
}
#else
// iOS: no direct USB serial. Network transports (Uniden SDS UDP, Icom LAN)
// are the supported path. SerialTransport is unavailable on iOS.
public final class SerialTransport {
    public init() {
        fatalError("Serial programming over USB requires macOS. Use network programming or export a file on iOS.")
    }
}
#endif

import Foundation

// MARK: - Baofeng UV-5R family clone protocol
//
// Documented clone protocol (miklor.com / CHIRP reference):
//   - Ident: 8-byte magic "\x50BBFF120100005" → radio ACK 0x06 → version + 0x06
//   - Read block:  "S" + addr(2B big-endian) + size(1B) → ACK 0x06 → size bytes + 0x06
//   - Write block: "X" + addr(2B big-endian) + size(1B) + data → ACK 0x06
//   - End: "E"
//
// Memory map (UV-5R, 8192 bytes):
//   0x0018 + (n-1)*16 : channel n record (128 channels)
//     0-3  rxFreq  little-endian BCD pairs of frequency × 100 Hz
//     4-7  txOffset same encoding
//     8-9  rxTone (0 = off; CTCSS = tone index + 1; DCS = 0x8000 | code)
//     10-11 txTone
//     12-15 flags
//   0x0F00 + (n-1)*7 : channel n display name (7 chars)

public enum BaofengError: Error, LocalizedError {
    case notAcknowledged
    case identFailed
    case outOfCapacity
    case deviceError(String)

    public var errorDescription: String? {
        switch self {
        case .notAcknowledged: return "Radio did not acknowledge"
        case .identFailed: return "Radio identification failed — is it in clone mode? (Hold MONI while powering on)"
        case .outOfCapacity: return "Channel list exceeds radio capacity"
        case let .deviceError(detail): return "Baofeng: \(detail)"
        }
    }
}

public enum BaofengUV5R {

    public static let magic: [UInt8] = [0x50, 0xBB, 0xFF, 0x12, 0x01, 0x00, 0x00, 0x05]
    public static let imageSize = 0x2000
    public static let blockSize = 0x40
    public static let channelCount = 128
    public static let channelRecordOffset = 0x0018
    public static let nameOffset = 0x0F00

    // MARK: Frequency encoding (little-endian BCD, ×100 Hz)

    public static func encodeFrequencyBCD(_ hz: Double) -> [UInt8] {
        let units = Int((hz / 100.0).rounded())
        let digits = String(format: "%08d", units)
        var bytes: [UInt8] = []
        var i = digits.count - 2
        while i >= 0 {
            let pair = digits[digits.index(digits.startIndex, offsetBy: i)..<digits.index(digits.startIndex, offsetBy: i + 2)]
            bytes.append(UInt8(pair) ?? 0)
            i -= 2
        }
        return bytes
    }

    public static func decodeFrequencyBCD(_ bytes: [UInt8]) -> Double {
        var digits = ""
        for b in bytes.reversed() {
            digits += String(format: "%02d", Int(b))
        }
        guard let units = Int(digits) else { return 0 }
        return Double(units) * 100.0
    }

    // MARK: Tone encoding

    static func encodeTone(ctcssHz: Double, dtcsCode: Int) -> UInt16 {
        if dtcsCode != 0 {
            return UInt16(0x8000 | (dtcsCode & 0x7FFF))
        }
        guard ctcssHz > 0 else { return 0 }
        if let index = CTCSSCatalog.tones.firstIndex(where: { abs($0 - ctcssHz) < 0.05 }) {
            return UInt16(index + 1)
        }
        return 0
    }

    static func decodeTone(_ value: UInt16) -> (ctcssHz: Double, dtcsCode: Int) {
        guard value != 0 else { return (0, 0) }
        if value & 0x8000 != 0 {
            return (0, Int(value & 0x7FFF))
        }
        let index = Int(value) - 1
        guard index >= 0, index < CTCSSCatalog.tones.count else { return (0, 0) }
        return (CTCSSCatalog.tones[index], 0)
    }

    // MARK: Protocol operations (macOS serial)

    #if os(macOS)
    static func ack(_ port: SerialTransport) throws {
        let data = try port.read(expected: 1, timeout: 3.0)
        guard data.first == 0x06 else { throw BaofengError.notAcknowledged }
    }

    public static func identify(port: SerialTransport) async throws -> String {
        port.drain()
        try port.write(Data(magic))
        try ack(port)
        let version = try port.read(expected: 8, timeout: 3.0)
        try port.read(expected: 1, timeout: 1.0)
        return String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func readImage(port: SerialTransport, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [UInt8] {
        var image = [UInt8](repeating: 0, count: imageSize)
        var offset = 0
        while offset < imageSize {
            let size = min(blockSize, imageSize - offset)
            var cmd: [UInt8] = [0x53] // "S"
            cmd.append(UInt8((offset >> 8) & 0xFF))
            cmd.append(UInt8(offset & 0xFF))
            cmd.append(UInt8(size))
            try port.write(Data(cmd))
            try ack(port)
            let data = try port.read(expected: size, timeout: 3.0)
            try port.read(expected: 1, timeout: 1.0)
            data.withUnsafeBytes { buf in
                image.replaceSubrange(offset..<(offset + size), with: buf)
            }
            offset += size
            progress?(Double(offset) / Double(imageSize))
        }
        return image
    }

    public static func writeImage(_ image: [UInt8], port: SerialTransport, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard image.count == imageSize else { throw BaofengError.deviceError("image size mismatch") }
        var offset = 0
        while offset < imageSize {
            let size = min(blockSize, imageSize - offset)
            var cmd: [UInt8] = [0x58] // "X"
            cmd.append(UInt8((offset >> 8) & 0xFF))
            cmd.append(UInt8(offset & 0xFF))
            cmd.append(UInt8(size))
            cmd.append(contentsOf: image[offset..<(offset + size)])
            try port.write(Data(cmd))
            try ack(port)
            offset += size
            progress?(Double(offset) / Double(imageSize))
        }
        try port.write(Data([0x45])) // "E" end
    }

    /// Full clone: read the radio's image, overlay channels, write back, verify.
    public static func writeChannels(_ channels: [CodeplugChannel], port: SerialTransport, progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> CodeplugWriteResult {
        guard channels.count <= channelCount else { throw BaofengError.outOfCapacity }
        let start = Date()

        progress?("Identifying radio", 0)
        _ = try await identify(port: port)
        try port.write(Data(magic))
        try ack(port)

        progress?("Reading radio image", 0)
        var image = try await readImage(port: port) { f in progress?("Reading radio image", f) }

        progress?("Building codeplug", 0.5)
        applyChannels(channels, to: &image)

        progress!("Writing radio", 0.5)
        try await writeImage(image, port: port) { f in progress?("Writing radio", 0.5 + f * 0.5) }

        progress!("Verifying", 1.0)
        var verify = try await readImage(port: port)
        applyChannels(channels, to: &verify)
        let verified = verify == image

        let errors = verified ? [] : ["Verification mismatch — re-clone recommended"]
        return CodeplugWriteResult(
            channelsWritten: channels.count,
            durationSeconds: Date().timeIntervalSince(start),
            deviceName: "Baofeng",
            errors: errors
        )
    }
    #endif

    // MARK: Image editing

    public static func applyChannels(_ channels: [CodeplugChannel], to image: inout [UInt8]) {
        for (index, channel) in channels.enumerated() where index < channelCount {
            let base = channelRecordOffset + index * 16
            guard base + 16 <= image.count else { continue }

            var record = [UInt8](repeating: 0, count: 16)
            let rx = encodeFrequencyBCD(channel.frequencyHz)
            let tx = encodeFrequencyBCD(channel.offsetHz)
            for i in 0..<4 {
                record[i] = i < rx.count ? rx[i] : 0
                record[4 + i] = i < tx.count ? tx[i] : 0
            }
            let rxTone = encodeTone(ctcssHz: channel.ctcssToneHz, dtcsCode: channel.dtcsCode)
            let txTone = encodeTone(ctcssHz: channel.ctcssToneHz, dtcsCode: channel.dtcsCode)
            record[8] = UInt8((rxTone >> 8) & 0xFF)
            record[9] = UInt8(rxTone & 0xFF)
            record[10] = UInt8((txTone >> 8) & 0xFF)
            record[11] = UInt8(txTone & 0xFF)
            // Flags: keep defaults; wide FM bit for .fm mode
            record[12] = channel.mode == .fm ? 0x01 : 0x00

            for i in 0..<16 {
                image[base + i] = record[i]
            }

            // Display name
            let nameBase = nameOffset + index * 7
            if nameBase + 7 <= image.count {
                var nameBytes = Array(channel.name.prefix(7).utf8)
                while nameBytes.count < 7 { nameBytes.append(0x20) }
                for i in 0..<7 {
                    image[nameBase + i] = nameBytes[i]
                }
            }
        }
    }

    // MARK: Read channels out of an image (for import from radio)

    public static func channelsFromImage(_ image: [UInt8]) -> [CodeplugChannel] {
        var channels: [CodeplugChannel] = []
        for index in 0..<channelCount {
            let base = channelRecordOffset + index * 16
            guard base + 16 <= image.count else { break }
            let rx = decodeFrequencyBCD(Array(image[base..<base + 4]))
            guard rx > 0 else { continue }
            let tx = decodeFrequencyBCD(Array(image[base + 4..<base + 8]))
            let rxTone = UInt16(image[base + 8]) << 8 | UInt16(image[base + 9])
            let tone = decodeTone(rxTone)

            let nameBase = nameOffset + index * 7
            var name = ""
            if nameBase + 7 <= image.count {
                name = String(decoding: image[nameBase..<nameBase + 7], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if name.isEmpty { name = "CH\(index + 1)" }

            channels.append(CodeplugChannel(
                name: name,
                frequencyHz: rx,
                offsetHz: tx,
                mode: .nfm,
                ctcssToneHz: tone.ctcssHz,
                dtcsCode: tone.dtcsCode
            ))
        }
        return channels
    }
}

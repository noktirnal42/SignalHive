import Foundation

/// First-pass VHF ACARS decoder for clean 2400 baud MSK/FM IQ captures.
///
/// The decoder keeps enough state to handle frames split across IQ chunks. It
/// demodulates baseband FM to frequency deviation, slices one bit per 2400 baud
/// symbol, then searches the resulting bitstream for ASCII ACARS blocks framed
/// by SOH/ETX.
public final class ACARSDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "ACARS"
    public let requiredBandwidth: Double = 25_000
    public var timestampProvider: @Sendable () -> Date = { .now }

    private static let baudRate = 2_400.0
    private static let nominalFrequencyHz = 131_550_000.0
    private static let maxBufferedBits = 16_384
    private static let maxRecentMessages = 500

    private var previousSample = ComplexFloat(i: 1, q: 0)
    private var symbolSamples: [Float] = []
    private var bitBuffer: [Int] = []
    private var recentMessages: [ACARSMessage] = []

    public init() {}

    public func reset() {
        previousSample = ComplexFloat(i: 1, q: 0)
        symbolSamples.removeAll(keepingCapacity: true)
        bitBuffer.removeAll(keepingCapacity: true)
        recentMessages.removeAll(keepingCapacity: true)
        timestampProvider = { .now }
    }

    public func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard sampleRate >= Self.baudRate * 2, !iq.isEmpty else { return [] }

        let audio = fmDiscriminator(iq: iq, sampleRate: sampleRate)
        bitBuffer.append(contentsOf: recoverBits(from: audio, sampleRate: sampleRate))

        let frames = extractFrames()
        return frames.compactMap { frame in
            let timestamp = timestampProvider()
            guard let message = decode(frame: frame, timestamp: timestamp) else { return nil }
            remember(message)
            return DecodedMessage(
                timestamp: timestamp,
                frequency: Self.nominalFrequencyHz,
                mode: identifier,
                payload: .acars(message)
            )
        }
    }

    public func allMessages() async -> [ACARSMessage] {
        recentMessages
    }

    // MARK: - Demodulation

    private func fmDiscriminator(iq: [ComplexFloat], sampleRate: Double) -> [Float] {
        var audio: [Float] = []
        audio.reserveCapacity(iq.count)

        let scale = Float(sampleRate) / (2 * Float.pi)
        for sample in iq {
            let product = sample * ComplexFloat(i: previousSample.i, q: -previousSample.q)
            audio.append(atan2f(product.q, product.i) * scale)
            previousSample = sample
        }

        return audio
    }

    private func recoverBits(from audio: [Float], sampleRate: Double) -> [Int] {
        let samplesPerSymbol = max(1, Int(round(sampleRate / Self.baudRate)))
        symbolSamples.append(contentsOf: audio)

        var bits: [Int] = []
        while symbolSamples.count >= samplesPerSymbol {
            let symbol = symbolSamples.prefix(samplesPerSymbol)
            let average = symbol.reduce(Float(0), +) / Float(samplesPerSymbol)
            bits.append(average >= 0 ? 1 : 0)
            symbolSamples.removeFirst(samplesPerSymbol)
        }

        let maxCarry = samplesPerSymbol * 2
        if symbolSamples.count > maxCarry {
            symbolSamples = Array(symbolSamples.suffix(maxCarry))
        }

        return bits
    }

    // MARK: - Framing

    private func extractFrames() -> [[UInt8]] {
        var frames: [[UInt8]] = []

        while let next = findNextFrame() {
            frames.append(next.bytes)
            let consumed = min(next.consumedBits, bitBuffer.count)
            bitBuffer.removeFirst(consumed)
        }

        if bitBuffer.count > Self.maxBufferedBits {
            bitBuffer = Array(bitBuffer.suffix(256))
        }

        return frames
    }

    private func findNextFrame() -> (bytes: [UInt8], consumedBits: Int)? {
        guard bitBuffer.count >= 24 else { return nil }

        var best: (bytes: [UInt8], consumedBits: Int)?
        for offset in 0..<8 where offset + 24 <= bitBuffer.count {
            for bitOrder in [BitOrder.lsbFirst, .msbFirst] {
                let bytes = bytesFromBuffer(offset: offset, bitOrder: bitOrder)
                guard let candidate = findFrame(in: bytes) else { continue }

                let consumed = offset + candidate.endByte * 8
                guard consumed > 0 else { continue }
                if best == nil || consumed < best!.consumedBits {
                    best = (candidate.frame, consumed)
                }
            }
        }

        return best
    }

    private func bytesFromBuffer(offset: Int, bitOrder: BitOrder) -> [UInt8] {
        var bytes: [UInt8] = []
        var idx = offset

        while idx + 8 <= bitBuffer.count {
            var value: UInt8 = 0
            for bit in 0..<8 {
                let input = UInt8(bitBuffer[idx + bit] & 1)
                switch bitOrder {
                case .lsbFirst:
                    value |= input << UInt8(bit)
                case .msbFirst:
                    value = (value << 1) | input
                }
            }
            bytes.append(value)
            idx += 8
        }

        return bytes
    }

    private func findFrame(in bytes: [UInt8]) -> (frame: [UInt8], endByte: Int)? {
        guard let start = bytes.firstIndex(of: 0x01) else { return nil } // SOH
        guard start + 2 < bytes.count else { return nil }

        for end in (start + 2)..<bytes.count where bytes[end] == 0x03 { // ETX
            let frame = Array(bytes[start...end])
            if isPlausible(frame: frame) {
                return (frame, end + 1)
            }
        }

        return nil
    }

    private func isPlausible(frame: [UInt8]) -> Bool {
        guard frame.count >= 4, frame.first == 0x01, frame.last == 0x03 else { return false }
        let body = frame.dropFirst().dropLast()
        guard !body.isEmpty else { return false }

        let printable = body.filter { byte in
            byte == 0x0D || byte == 0x0A || byte == 0x09 || (0x20...0x7E).contains(byte)
        }
        return printable.count == body.count && printable.count >= 2
    }

    // MARK: - Message extraction

    private func decode(frame: [UInt8], timestamp: Date) -> ACARSMessage? {
        guard isPlausible(frame: frame) else { return nil }

        let bodyBytes = frame.dropFirst().dropLast()
        guard let rawText = String(bytes: bodyBytes, encoding: .ascii) else { return nil }

        let text = rawText
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let label = extractLabel(from: text)
        let registration = extractRegistration(from: text)
        let flightId = extractFlightID(from: text, label: label, registration: registration)
        let kind = classifyKind(label: label, text: text)
        return ACARSMessage(
            timestamp: timestamp,
            frequency: Self.nominalFrequencyHz,
            label: label,
            text: text,
            flightId: flightId,
            registration: registration,
            kind: kind
        )
    }

    private func remember(_ message: ACARSMessage) {
        recentMessages.append(message)
        if recentMessages.count > Self.maxRecentMessages {
            recentMessages.removeFirst(recentMessages.count - Self.maxRecentMessages)
        }
    }

    private func extractLabel(from text: String) -> String {
        let compact = text.filter { $0.isLetter || $0.isNumber }
        guard compact.count >= 2 else { return "--" }
        return String(compact.prefix(2))
    }

    private func extractFlightID(from text: String, label: String, registration: String?) -> String? {
        let candidates = acarsTokens(in: text).filter { candidate in
            candidate != label && candidate != registration
        }

        if let flight = candidates.first(where: isFlightIdentifier) {
            return flight
        }

        return registration ?? candidates.first { candidate in
            (2...8).contains(candidate.count) && candidate.contains { $0.isNumber }
        }
    }

    private func extractRegistration(from text: String) -> String? {
        acarsTokens(in: text).first(where: isRegistration)
    }

    private func classifyKind(label: String, text: String) -> ACARSMessageKind {
        let upper = text.uppercased()

        if upper.contains("METAR") || upper.contains("TAF") || upper.contains("SIGMET") || upper.contains("WX") {
            return .weather
        }
        if upper.contains("CLEARANCE") || upper.contains(" ATC ") || upper.contains(" CLR ") {
            return .clearance
        }
        if upper.contains("MAINT") || upper.contains("FAULT") || upper.contains("MEL") || upper.contains("ENG") {
            return .maintenance
        }
        if upper.contains(" OUT ") || upper.hasSuffix(" OUT") || upper.contains(" OFF ") {
            return .departure
        }
        if upper.contains(" ON ") || upper.contains(" IN ") || upper.hasSuffix(" IN") {
            return .arrival
        }
        if label.hasPrefix("Q") || upper.contains("POS ") || upper.contains("POSITION") {
            return .position
        }
        return .freeText
    }

    private func acarsTokens(in text: String) -> [String] {
        text.uppercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "-") }
            .map(String.init)
    }

    private func isFlightIdentifier(_ token: String) -> Bool {
        guard (3...8).contains(token.count) else { return false }

        let scalars = Array(token.unicodeScalars)
        let letterPrefixCount = scalars.prefix { CharacterSet.uppercaseLetters.contains($0) }.count
        let digitCount = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let suffixCount = scalars.count - letterPrefixCount - digitCount

        guard (2...3).contains(letterPrefixCount), digitCount >= 1 else { return false }
        return suffixCount == 0 || (suffixCount == 1 && CharacterSet.uppercaseLetters.contains(scalars.last!))
    }

    private func isRegistration(_ token: String) -> Bool {
        if token.first == "N" {
            let suffix = token.dropFirst()
            let digitCount = suffix.prefix { $0.isNumber }.count
            let letterCount = suffix.reversed().prefix { $0.isLetter }.count
            return (1...5).contains(digitCount) && letterCount <= 2 && digitCount + letterCount == suffix.count
        }

        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let prefix = parts[0]
        let suffix = parts[1]
        guard (1...2).contains(prefix.count), suffix.count == 4 else { return false }
        return prefix.allSatisfy(\.isLetter) && suffix.allSatisfy(\.isLetter)
    }

    private enum BitOrder {
        case lsbFirst
        case msbFirst
    }
}

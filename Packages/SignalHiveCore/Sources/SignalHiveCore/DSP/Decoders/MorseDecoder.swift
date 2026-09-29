import Foundation

public enum MorseCodec {
    public static let characterToPattern: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.",
        "G": "--.", "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..",
        "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
        "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "'": ".----.", "!": "-.-.--",
        "/": "-..-.", "(": "-.--.", ")": "-.--.-", "&": ".-...", ":": "---...",
        ";": "-.-.-.", "=": "-...-", "+": ".-.-.", "-": "-....-", "_": "..--.-",
        "\"": ".-..-.", "$": "...-..-", "@": ".--.-."
    ]

    public static let patternToCharacter: [String: Character] = {
        Dictionary(uniqueKeysWithValues: characterToPattern.map { ($0.value, $0.key) })
    }()

    public struct DecodeResult: Sendable, Equatable {
        public let text: String
        public let wordsPerMinute: Double
        public let confidence: Double

        public init(text: String, wordsPerMinute: Double, confidence: Double) {
            self.text = text
            self.wordsPerMinute = wordsPerMinute
            self.confidence = confidence
        }
    }

    public static func encodeToPatterns(_ text: String) -> [String] {
        normalizedWords(text).map { word in
            word.compactMap { characterToPattern[$0] }.joined(separator: " ")
        }
    }

    public static func encodeAudio(
        text: String,
        sampleRate: Double,
        wordsPerMinute: Double = 18,
        toneHz: Double = 700,
        amplitude: Float = 0.8,
        includeTrailingSilence: Bool = true
    ) -> [Float] {
        let envelope = encodeEnvelope(
            text: text,
            sampleRate: sampleRate,
            wordsPerMinute: wordsPerMinute,
            includeTrailingSilence: includeTrailingSilence
        )
        var phase = 0.0
        return envelope.map { keyDown in
            phase += 2.0 * .pi * toneHz / sampleRate
            return keyDown ? amplitude * Float(sin(phase)) : 0
        }
    }

    public static func encodeIQ(
        text: String,
        sampleRate: Double,
        wordsPerMinute: Double = 18,
        toneHz: Double = 700,
        amplitude: Float = 0.8,
        includeTrailingSilence: Bool = true
    ) -> [ComplexFloat] {
        let envelope = encodeEnvelope(
            text: text,
            sampleRate: sampleRate,
            wordsPerMinute: wordsPerMinute,
            includeTrailingSilence: includeTrailingSilence
        )
        var phase = 0.0
        return envelope.map { keyDown in
            phase += 2.0 * .pi * toneHz / sampleRate
            let gain = keyDown ? amplitude : 0
            return ComplexFloat(i: gain * Float(cos(phase)), q: gain * Float(sin(phase)))
        }
    }

    public static func decodeAudio(_ audio: [Float], sampleRate: Double) -> DecodeResult? {
        let window = max(1, Int(sampleRate / 800))
        return decodeEnvelope(smoothedEnvelope(audio.map(abs), window: window), sampleRate: sampleRate)
    }

    public static func decodeIQ(_ iq: [ComplexFloat], sampleRate: Double) -> DecodeResult? {
        decodeEnvelope(iq.map(\.magnitude), sampleRate: sampleRate)
    }

    public static func decodeEnvelope(_ envelope: [Float], sampleRate: Double) -> DecodeResult? {
        guard sampleRate > 0, envelope.count > 2 else { return nil }
        guard let maxValue = envelope.max(), maxValue > 0.01 else { return nil }
        let sorted = envelope.sorted()
        let low = sorted[max(0, sorted.count / 10)]
        let high = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        let threshold = low + max(0.05, (high - low) * 0.45)
        let keyed = envelope.map { $0 >= threshold }
        let runs = runs(from: keyed).filter { $0.length > 0 }
        let onRuns = runs.filter(\.isOn).map(\.length)
        guard let unitSamples = estimatedUnitSamples(from: onRuns), unitSamples > 0 else { return nil }

        var output = ""
        var currentPattern = ""
        var validSymbols = 0
        var totalSymbols = 0

        func flushCharacter() {
            guard !currentPattern.isEmpty else { return }
            totalSymbols += 1
            if let character = patternToCharacter[currentPattern] {
                output.append(character)
                validSymbols += 1
            }
            currentPattern.removeAll()
        }

        for run in runs {
            let units = Double(run.length) / Double(unitSamples)
            if run.isOn {
                currentPattern.append(units < 2.0 ? "." : "-")
            } else if units >= 6.0 {
                flushCharacter()
                if !output.isEmpty, output.last != " " {
                    output.append(" ")
                }
            } else if units >= 2.0 {
                flushCharacter()
            }
        }
        flushCharacter()

        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let unitSeconds = Double(unitSamples) / sampleRate
        let wordsPerMinute = unitSeconds > 0 ? 1.2 / unitSeconds : 0
        let confidence = totalSymbols == 0 ? 0 : Double(validSymbols) / Double(totalSymbols)
        return DecodeResult(text: text, wordsPerMinute: wordsPerMinute, confidence: confidence)
    }

    private static func encodeEnvelope(
        text: String,
        sampleRate: Double,
        wordsPerMinute: Double,
        includeTrailingSilence: Bool
    ) -> [Bool] {
        let unitSeconds = 1.2 / max(1, wordsPerMinute)
        let samplesPerUnit = max(1, Int(round(sampleRate * unitSeconds)))
        let words = normalizedWords(text)
        var envelope: [Bool] = []

        func append(_ keyDown: Bool, units: Int) {
            envelope.append(contentsOf: repeatElement(keyDown, count: samplesPerUnit * units))
        }

        for (wordIndex, word) in words.enumerated() {
            let characters = word.compactMap { characterToPattern[$0] }
            for (characterIndex, pattern) in characters.enumerated() {
                for (symbolIndex, symbol) in pattern.enumerated() {
                    append(true, units: symbol == "." ? 1 : 3)
                    if symbolIndex < pattern.count - 1 {
                        append(false, units: 1)
                    }
                }
                if characterIndex < characters.count - 1 {
                    append(false, units: 3)
                }
            }
            if wordIndex < words.count - 1 {
                append(false, units: 7)
            }
        }

        if includeTrailingSilence {
            append(false, units: 7)
        }
        return envelope
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.uppercased()
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                String(word.filter { characterToPattern[$0] != nil })
            }
            .filter { !$0.isEmpty }
    }

    private static func runs(from keyed: [Bool]) -> [(isOn: Bool, length: Int)] {
        guard let first = keyed.first else { return [] }
        var runs: [(isOn: Bool, length: Int)] = []
        var current = first
        var length = 0

        for value in keyed {
            if value == current {
                length += 1
            } else {
                runs.append((current, length))
                current = value
                length = 1
            }
        }
        runs.append((current, length))

        while runs.first?.isOn == false {
            runs.removeFirst()
        }
        return runs
    }

    private static func estimatedUnitSamples(from onRuns: [Int]) -> Int? {
        guard let shortest = onRuns.min(), shortest > 0 else { return nil }
        let dotCandidates = onRuns.filter { Double($0) <= Double(shortest) * 1.8 }
        let samples = dotCandidates.isEmpty ? [shortest] : dotCandidates.sorted()
        return samples[samples.count / 2]
    }

    private static func smoothedEnvelope(_ values: [Float], window: Int) -> [Float] {
        guard window > 1, !values.isEmpty else { return values }
        var output = [Float](repeating: 0, count: values.count)
        var sum: Float = 0
        for index in values.indices {
            sum += values[index]
            if index >= window {
                sum -= values[index - window]
            }
            let count = min(index + 1, window)
            output[index] = sum / Float(count)
        }
        return output
    }
}

public final class MorseDecoder: SignalDecoder, @unchecked Sendable {
    public let identifier = "Morse"
    public let requiredBandwidth: Double = 500
    public var timestampProvider: @Sendable () -> Date = { .now }

    private static let maxBufferedSamples = 480_000
    private var envelopeBuffer: [Float] = []
    private var recentMessages: [MorseMessage] = []

    public init() {}

    public func reset() {
        envelopeBuffer.removeAll(keepingCapacity: true)
        recentMessages.removeAll(keepingCapacity: true)
        timestampProvider = { .now }
    }

    public func process(iq: [ComplexFloat], sampleRate: Double) -> [DecodedMessage] {
        guard sampleRate > 0, !iq.isEmpty else { return [] }
        envelopeBuffer.append(contentsOf: iq.map(\.magnitude))
        if envelopeBuffer.count > Self.maxBufferedSamples {
            envelopeBuffer = Array(envelopeBuffer.suffix(Self.maxBufferedSamples))
        }

        guard hasTrailingSilence(sampleRate: sampleRate),
              let result = MorseCodec.decodeEnvelope(envelopeBuffer, sampleRate: sampleRate) else {
            return []
        }

        let message = MorseMessage(
            timestamp: timestampProvider(),
            text: result.text,
            wordsPerMinute: result.wordsPerMinute,
            confidence: result.confidence
        )
        envelopeBuffer.removeAll(keepingCapacity: true)
        remember(message)
        return [
            DecodedMessage(
                timestamp: message.timestamp,
                frequency: 0,
                mode: identifier,
                payload: .morse(message)
            )
        ]
    }

    public func allMessages() async -> [MorseMessage] {
        recentMessages
    }

    private func hasTrailingSilence(sampleRate: Double) -> Bool {
        guard let peak = envelopeBuffer.max(), peak > 0.01 else { return false }
        let threshold = peak * 0.2
        let required = max(1, Int(sampleRate * 0.2))
        var count = 0
        for value in envelopeBuffer.reversed() {
            if value <= threshold {
                count += 1
                if count >= required { return true }
            } else {
                return false
            }
        }
        return false
    }

    private func remember(_ message: MorseMessage) {
        recentMessages.append(message)
        if recentMessages.count > 200 {
            recentMessages.removeFirst(recentMessages.count - 200)
        }
    }
}

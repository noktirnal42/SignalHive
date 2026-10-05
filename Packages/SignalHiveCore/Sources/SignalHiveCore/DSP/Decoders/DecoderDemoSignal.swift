import Foundation

public enum DecoderDemoSignal {
    public static func morseIQ(
        text: String,
        sampleRate: Double = 48_000,
        wordsPerMinute: Double = 20,
        toneHz: Double = 700
    ) -> [ComplexFloat] {
        MorseCodec.encodeIQ(
            text: text,
            sampleRate: sampleRate,
            wordsPerMinute: wordsPerMinute,
            toneHz: toneHz
        )
    }

    public static func acarsIQ(
        text: String,
        sampleRate: Double = 48_000,
        deviationHz: Double = 1_200
    ) -> [ComplexFloat] {
        let body = sanitizedACARSText(text)
        let bytes = [UInt8(0x01)] + Array(body.utf8) + [UInt8(0x03)]
        let samplesPerSymbol = max(1, Int(round(sampleRate / 2_400)))
        let deviation = max(100, min(abs(deviationHz), sampleRate / 4))
        var samples: [ComplexFloat] = []
        samples.reserveCapacity((bytes.count * 8 + 40) * samplesPerSymbol)

        var phase = 0.0
        func append(bit: Int) {
            let frequency = bit == 1 ? deviation : -deviation
            let phaseStep = 2.0 * Double.pi * frequency / sampleRate
            for _ in 0..<samplesPerSymbol {
                phase += phaseStep
                samples.append(ComplexFloat(i: Float(cos(phase)), q: Float(sin(phase))))
            }
        }

        for _ in 0..<16 { append(bit: 0) }
        for byte in bytes {
            for bit in 0..<8 {
                append(bit: Int((byte >> UInt8(bit)) & 1))
            }
        }
        for _ in 0..<24 { append(bit: 0) }
        return samples
    }

    private static func sanitizedACARSText(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .filter { character in
                character == " " || character == "\t" || character.unicodeScalars.allSatisfy { scalar in
                    (0x20...0x7E).contains(Int(scalar.value))
                }
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Q0 N123AB DAL123 POS 37.62 -122.38" : cleaned
    }
}

import Testing
import Foundation
@testable import SignalHiveCore

struct DecoderWorkbenchTests {
    @Test func morsePatternsDecodeToText() {
        let result = DecoderWorkbench.decodeMorsePatterns("... --- ... / -.-. --.-")

        #expect(result.status == .decoded)
        #expect(result.summary == "SOS CQ")
        #expect(result.details.contains("5 known symbols"))
        #expect(result.details.contains("0 unknown symbols"))
    }

    @Test func morseTextEncodesToPatterns() {
        #expect(DecoderWorkbench.encodeMorseText("CQ TEST") == "-.-. --.- / - . ... -")
    }

    @Test func acarsTextGetsAWorkbenchSummary() throws {
        let messages = DecoderWorkbench.decodeACARSText("Q0 N123AB DAL123 POS 37.62 -122.38")
        let message = try #require(messages.first)

        #expect(message.status == .decoded)
        #expect(message.decoder == "ACARS")
        #expect(message.details.contains("Label Q0"))
        #expect(message.details.contains("Position"))
        #expect(message.details.contains("Registration N123AB"))
        #expect(message.details.contains("Flight DAL123"))
    }

    @Test func aisNMEAPositionGetsAWorkbenchSummary() throws {
        let sentence = makeAISPositionSentence(
            mmsi: 366123456,
            latitude: 47.5000,
            longitude: -122.3321,
            speedOverGround: 12.3,
            courseOverGround: 271.4,
            trueHeading: 270
        )

        let messages = DecoderWorkbench.decodeAISNMEA(sentence)
        let message = try #require(messages.first)

        #expect(message.status == .decoded)
        #expect(message.decoder == "AIS")
        #expect(message.details.contains("MMSI 366123456"))
        #expect(message.details.contains("Type 1"))
        #expect(message.summary.contains("47.50000"))
        #expect(message.summary.contains("-122.33210"))
        #expect(message.summary.contains("12.3 kt"))
    }

    @Test func invalidAISLineIsRejected() throws {
        let message = try #require(DecoderWorkbench.decodeAISNMEA("not nmea").first)

        #expect(message.status == .rejected)
        #expect(message.summary.contains("Could not parse AIS"))
    }

    private func makeAISPositionSentence(
        mmsi: Int,
        latitude: Double,
        longitude: Double,
        speedOverGround: Double,
        courseOverGround: Double,
        trueHeading: Int
    ) -> String {
        var bits = [Int](repeating: 0, count: 168)
        setUnsigned(1, start: 0, length: 6, in: &bits)
        setUnsigned(0, start: 6, length: 2, in: &bits)
        setUnsigned(mmsi, start: 8, length: 30, in: &bits)
        setUnsigned(0, start: 38, length: 4, in: &bits)
        setSigned(0, start: 42, length: 8, in: &bits)
        setUnsigned(Int((speedOverGround * 10).rounded()), start: 50, length: 10, in: &bits)
        setUnsigned(0, start: 60, length: 1, in: &bits)
        setSigned(Int((longitude * 600_000).rounded()), start: 61, length: 28, in: &bits)
        setSigned(Int((latitude * 600_000).rounded()), start: 89, length: 27, in: &bits)
        setUnsigned(Int((courseOverGround * 10).rounded()), start: 116, length: 12, in: &bits)
        setUnsigned(trueHeading, start: 128, length: 9, in: &bits)
        setUnsigned(42, start: 137, length: 6, in: &bits)

        let payload = encodeAISPayload(bits)
        let body = "AIVDM,1,1,,A,\(payload),0"
        let checksum = body.utf8.reduce(UInt8(0)) { $0 ^ $1 }
        return String(format: "!%@*%02X", body, checksum)
    }

    private func setUnsigned(_ value: Int, start: Int, length: Int, in bits: inout [Int]) {
        for offset in 0..<length {
            let shift = length - offset - 1
            bits[start + offset] = (value >> shift) & 1
        }
    }

    private func setSigned(_ value: Int, start: Int, length: Int, in bits: inout [Int]) {
        let encoded = value >= 0 ? value : (1 << length) + value
        setUnsigned(encoded, start: start, length: length, in: &bits)
    }

    private func encodeAISPayload(_ bits: [Int]) -> String {
        var payload = ""
        for offset in stride(from: 0, to: bits.count, by: 6) {
            var value = 0
            for bit in 0..<6 {
                value = (value << 1) | bits[offset + bit]
            }
            let scalar = value < 40 ? value + 48 : value + 56
            payload.append(Character(UnicodeScalar(scalar)!))
        }
        return payload
    }
}

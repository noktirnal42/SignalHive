import Testing
import Foundation
@testable import SignalHiveCore

/// The bits of a string's bytes as an HDLC link sends them: each byte least significant bit first.
private func linkBits(of text: String) -> [Int] {
    Array(text.utf8).flatMap { byte in (0..<8).map { Int((byte >> UInt8($0)) & 1) } }
}

/// A message's six-bit armour (as in an !AIVDM sentence) back to its bits, first bit first.
private func messageBits(armoured payload: String) -> [Int] {
    payload.unicodeScalars.flatMap { scalar -> [Int] in
        let raw = Int(scalar.value) - 48
        let value = raw > 40 ? raw - 8 : raw
        return (0..<6).map { (value >> (5 - $0)) & 1 }
    }
}

/// A frame as it arrives after un-stuffing: the message, then its 16-bit check, low bit first.
private func frame(for message: [Int]) -> [Int] {
    let check = AISFrameCheck.checksum(message)
    return message + (0..<16).map { Int((check >> UInt16($0)) & 1) }
}

private func typeBits(_ type: Int, then rest: Int = 162) -> [Int] {
    (0..<6).map { (type >> (5 - $0)) & 1 } + [Int](repeating: 0, count: rest)
}

struct AISFrameCheckTests {
    /// The published check value of CRC-16/X.25 for "123456789", so the check cannot be wrong in the same way as the code that
    /// uses it.
    @Test func theChecksumMatchesTheStandardCheckValue() {
        #expect(AISFrameCheck.checksum(linkBits(of: "123456789")) == 0x906E)
    }

    @Test func aRealMessageWithItsCheckPassesAndComesBackWithoutTheCheck() throws {
        let message = messageBits(armoured: "15M:Ih001sG@0Q8K;P8:V`MD0000")
        #expect(message.count == 168)
        let payload = try #require(AISFrameCheck.payload(fromFrame: frame(for: message)))
        #expect(payload == message)
    }

    @Test func oneWrongBitFailsTheCheck() {
        let good = frame(for: messageBits(armoured: "15M:Ih001sG@0Q8K;P8:V`MD0000"))
        for index in [0, 7, 100, good.count - 1] {
            var bad = good
            bad[index] ^= 1
            #expect(AISFrameCheck.payload(fromFrame: bad) == nil, "bit \(index)")
        }
    }

    @Test func aTypeAISDoesNotDefineIsRefusedEvenWithAValidCheck() {
        for type in [0, 28, 58, 61, 63] {
            #expect(AISFrameCheck.payload(fromFrame: frame(for: typeBits(type))) == nil, "type \(type)")
        }
        for type in [1, 5, 18, 27] {
            #expect(AISFrameCheck.payload(fromFrame: frame(for: typeBits(type))) != nil, "type \(type)")
        }
    }

    @Test func tooShortToBeAMessageIsRefused() {
        #expect(AISFrameCheck.payload(fromFrame: []) == nil)
        #expect(AISFrameCheck.payload(fromFrame: frame(for: typeBits(1, then: 10))) == nil)
    }

    @Test func randomBitsAlmostNeverPass() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func nextBit() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) & 1)
        }
        var passed = 0
        for _ in 0..<5_000 where AISFrameCheck.payload(fromFrame: (0..<200).map { _ in nextBit() }) != nil { passed += 1 }
        #expect(passed == 0, "a 1-in-65536 check, and one more filter on the type, over 5000 frames")
    }
}

struct AISDecoderNoiseTests {
    /// What the live decoder did on a dongle with no ship nearby: every pair of flag patterns in the noise became a vessel.
    @Test func noiseProducesNoMessages() {
        var state: UInt64 = 42
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
        }
        let decoder = AISDecoder()
        var heard = 0
        for _ in 0..<8 {
            let block = (0..<48_000).map { _ in ComplexFloat(i: next(), q: next()) }
            heard += decoder.process(iq: block, sampleRate: 96_000).count
        }
        #expect(heard == 0)
    }
}

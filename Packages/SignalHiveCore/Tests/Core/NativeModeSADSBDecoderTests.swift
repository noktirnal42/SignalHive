#if canImport(RTLSDRDecoders)
import Testing
@testable import SignalHiveCore

struct NativeModeSADSBDecoderTests {
    @Test func decodesPublishedIdentificationFrame() throws {
        let decoder = NativeModeSADSBDecoder()
        let frame = try #require(decoder.decodeFrame(hex: "8D4840D6202CC371C32CE0576098"))

        #expect(frame.icaoAddress == 0x4840D6)
        #expect(frame.downlinkFormat == 17)
        guard case let .identification(callsign, category) = frame.payload else {
            Issue.record("unexpected payload \(frame.payload)")
            return
        }
        #expect(callsign == "KLM1023")
        #expect(category == 0)
    }
}
#endif

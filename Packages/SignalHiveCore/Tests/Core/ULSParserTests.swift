import Foundation
import Testing
import SignalHiveCore

struct ULSParserTests {

    static var realArchiveDirectory: URL? {
        guard let value = ProcessInfo.processInfo.environment["SIGNALHIVE_REAL_ARCHIVES"], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    @Test func parsesRealAircraftDump() async throws {
        guard let directory = Self.realArchiveDirectory else {
            print("Skipping real aircraft parser test: set SIGNALHIVE_REAL_ARCHIVES to a directory containing EN.dat and HD.dat.")
            return
        }
        let enURL = directory.appendingPathComponent("EN.dat")
        let hdURL = directory.appendingPathComponent("HD.dat")
        guard FileManager.default.fileExists(atPath: enURL.path),
              FileManager.default.fileExists(atPath: hdURL.path) else {
            print("Skipping real aircraft parser test: \(directory.path) does not contain EN.dat and HD.dat.")
            return
        }

        let en = try ULSParser.parseTable(at: enURL)
        let hd = try ULSParser.parseTable(at: hdURL)

        #expect(en.entities.count > 1000)
        #expect(hd.licenses.count > 1000)

        // Spot-check the known record: uid 3923394, call sign 245DS, service AC
        let known = hd.licenses.first { $0.uid == 3_923_394 }
        #expect(known?.callSign == "245DS")
        #expect(known?.radioServiceCode == "AC")
        #expect(known?.licenseStatus == "A")

        // Entities carry names and state
        let withNames = en.entities.filter { !$0.name.isEmpty }
        #expect(!withNames.isEmpty)
        let withState = en.entities.filter { !$0.state.isEmpty }
        #expect(!withState.isEmpty)
    }

    @Test func frequencyEncodingRoundTrip() {
        let hz = 155_475_000.0
        let encoded = BaofengUV5R.encodeFrequencyBCD(hz)
        let decoded = BaofengUV5R.decodeFrequencyBCD(encoded)
        #expect(abs(decoded - hz) < 100)
    }

    @Test func chirpCSVRoundTrip() {
        let channels = [
            CodeplugChannel(name: "SHERIFF", frequencyHz: 155_475_000, mode: .nfm, ctcssToneHz: 123.0),
            CodeplugChannel(name: "AIR", frequencyHz: 121_900_000, mode: .am),
            CodeplugChannel(name: "REPEATER", frequencyHz: 146_880_000, offsetHz: -600_000),
        ]
        let csv = try! CHIRPCSVExporter.csv(for: channels)
        let parsed = CHIRPCSVExporter.parse(csv: csv)
        #expect(parsed.count == 3)
        #expect(abs(parsed[0].frequencyHz - 155_475_000) < 1)
        #expect(parsed[0].ctcssToneHz == 123.0)
        #expect(abs(parsed[2].offsetHz + 600_000) < 1)
    }
}

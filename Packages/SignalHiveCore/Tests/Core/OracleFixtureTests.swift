import Testing
import Foundation

/// The SGP4 oracle is data produced by an independent implementation (python-sgp4 on the official verification
/// set). These tests keep that data honest: if someone regenerates it badly, the orbit tests that read it must not
/// quietly pass on an empty or truncated file.
struct OracleFixtureTests {
    private func cases() throws -> [[String: Any]] {
        let root = try #require(try Fixtures.json("sgp4-oracle.json") as? [String: Any])
        return try #require(root["cases"] as? [[String: Any]])
    }

    @Test func oracleFileHasTheVerificationSet() throws {
        let all = try cases()
        #expect(all.count >= 30)

        let nearEarth = all.filter { ($0["periodMinutes"] as? Double ?? .infinity) < 225 }
        #expect(nearEarth.count >= 10)
        for entry in nearEarth {
            let samples = entry["samples"] as? [[String: Any]] ?? []
            #expect(samples.count >= 6, "case \(entry["name"] ?? "?") has \(samples.count) samples")
        }

        #expect(all.contains { !($0["error"] is NSNull) && $0["error"] != nil }, "no case records an SGP4 error code")

        for entry in all {
            for sample in entry["samples"] as? [[String: Any]] ?? [] {
                let r = sample["r"] as? [Double] ?? []
                #expect(r.count == 3 && r.allSatisfy(\.isFinite), "case \(entry["name"] ?? "?") has a non-finite position")
            }
        }
    }
}

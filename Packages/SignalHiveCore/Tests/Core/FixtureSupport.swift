import Foundation

/// Files under `Tests/Core/Fixtures`: reference data produced outside SignalHive (the SGP4 oracle, saved feed responses).
enum Fixtures {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "fixture \(name) is not in the test bundle" }
    }

    static func data(_ name: String) throws -> Data {
        let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { throw Missing(name: name) }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

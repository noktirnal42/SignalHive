import Foundation

/// Hand-built ULS tables using the real FCC column layout (verified against live data).
/// Each helper places values at the documented column indexes.
enum FixtureTables {

    private static func row(_ size: Int, _ cells: [Int: String]) -> String {
        var fields = Array(repeating: "", count: size)
        for (index, value) in cells { fields[index] = value }
        return fields.joined(separator: "|")
    }

    private static func hd(_ uid: Int, _ call: String, status: String, service: String) -> String {
        row(60, [0: "HD", 1: "\(uid)", 4: call, 5: status, 6: service, 7: "01/02/2020", 8: "01/02/2030"])
    }

    private static func en(_ uid: Int, _ call: String, type: String, name: String,
                           city: String, state: String, zip: String) -> String {
        row(30, [0: "EN", 1: "\(uid)", 4: call, 5: type, 7: name, 16: city, 17: state, 18: zip])
    }

    private static func lo(_ uid: Int, _ call: String, loc: Int, city: String, county: String, state: String,
                           lat: (String, String, String, String)? = nil,
                           lon: (String, String, String, String)? = nil) -> String {
        var cells: [Int: String] = [0: "LO", 1: "\(uid)", 4: call, 8: "\(loc)", 12: city, 13: county, 14: state]
        if let lat { cells[19] = lat.0; cells[20] = lat.1; cells[21] = lat.2; cells[22] = lat.3 }
        if let lon { cells[23] = lon.0; cells[24] = lon.1; cells[25] = lon.2; cells[26] = lon.3 }
        return row(51, cells)
    }

    private static func fr(_ uid: Int, _ call: String, loc: Int, mhz: String, cls: String, power: String) -> String {
        row(30, [0: "FR", 1: "\(uid)", 4: call, 6: "\(loc)", 8: cls, 10: mhz, 15: power])
    }

    private static func em(_ uid: Int, _ call: String, loc: Int, mhz: String, designator: String) -> String {
        row(16, [0: "EM", 1: "\(uid)", 4: call, 5: "\(loc)", 7: mhz, 9: designator])
    }

    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tables: [String: [String]] = [
            "HD": [
                hd(1001, "KAAA111", status: "A", service: "PW"),
                hd(1002, "KBBB222", status: "A", service: "IG"),
                hd(1003, "KDDD444", status: "A", service: "HA"),
                hd(1004, "KCCC333", status: "C", service: "PW"),   // cancelled: must be dropped
            ],
            "EN": [
                // Contact row appears BEFORE the licensee row; the licensee must win.
                en(1001, "KAAA111", type: "CL", name: "JOHN CONTACT", city: "MOBILE", state: "AL", zip: "36601"),
                en(1001, "KAAA111", type: "L", name: "COFFEE COUNTY SHERIFF", city: "ENTERPRISE", state: "AL", zip: "36330"),
                en(1002, "KBBB222", type: "L", name: "MULTI STATE UTILITY", city: "DOTHAN", state: "AL", zip: "36301"),
                en(1003, "KDDD444", type: "L", name: "OZARK FAMILY", city: "OZARK", state: "AL", zip: "36360"),
                en(1004, "KCCC333", type: "L", name: "GONE AWAY LLC", city: "ENTERPRISE", state: "AL", zip: "36330"),
            ],
            "LO": [
                lo(1001, "KAAA111", loc: 1, city: "ENTERPRISE", county: "COFFEE", state: "AL",
                   lat: ("31", "19", "7.0", "N"), lon: ("85", "49", "58.0", "W")),
                lo(1001, "KAAA111", loc: 2, city: "ENTERPRISE", county: "COFFEE", state: "AL"),   // no coordinates
                lo(1002, "KBBB222", loc: 1, city: "DOTHAN", county: "HOUSTON", state: "AL",
                   lat: ("31", "13", "0.0", "N"), lon: ("85", "23", "0.0", "W")),
                lo(1002, "KBBB222", loc: 2, city: "ATLANTA", county: "FULTON", state: "GA",
                   lat: ("33", "45", "0.0", "N"), lon: ("84", "23", "0.0", "W")),
                lo(1004, "KCCC333", loc: 1, city: "ENTERPRISE", county: "COFFEE", state: "AL",
                   lat: ("31", "19", "7.0", "N"), lon: ("85", "49", "58.0", "W")),
            ],
            "FR": [
                fr(1001, "KAAA111", loc: 1, mhz: "856.01250000", cls: "FB2", power: "100.000"),
                fr(1001, "KAAA111", loc: 2, mhz: "155.47500000", cls: "MO", power: "35.000"),
                fr(1002, "KBBB222", loc: 1, mhz: "452.50000000", cls: "FB", power: "50.000"),
                fr(1002, "KBBB222", loc: 2, mhz: "452.60000000", cls: "FB", power: "50.000"),
                fr(1004, "KCCC333", loc: 1, mhz: "460.00000000", cls: "FB", power: "10.000"),
            ],
            "EM": [
                em(1001, "KAAA111", loc: 1, mhz: "856.01250000", designator: "8K10F1E"),
                em(1001, "KAAA111", loc: 1, mhz: "856.01250000", designator: "20K0F3E"),
                em(1001, "KAAA111", loc: 2, mhz: "155.47500000", designator: "11K2F3E"),
                em(1002, "KBBB222", loc: 1, mhz: "452.50000000", designator: "20K0F3E"),
            ],
        ]
        for (name, lines) in tables {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("\(name).dat"), atomically: true, encoding: .utf8)
        }
    }
}

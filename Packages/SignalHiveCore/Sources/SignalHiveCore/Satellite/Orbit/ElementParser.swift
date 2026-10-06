import Foundation

/// Reads element sets from the formats feeds publish: OMM as JSON or CSV (CelesTrak's GP data, the format that
/// replaced TLEs for new objects) and the legacy two- and three-line TLE. A bad row never fails the whole feed: it is
/// counted in `rejected` with the reason, and the rest are kept.
public enum ElementParser {
    public struct Rejection: Sendable, Equatable {
        /// Zero-based index of the row (JSON, CSV: after the header) or element set (TLE) in the feed.
        public let position: Int
        public let reason: String
    }

    public struct Result: Sendable {
        public var elements: [OrbitalElements]
        public var rejected: [Rejection]
    }

    /// The body was not element data at all (an HTML error page, "No GP data found", a JSON error object).
    public struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    // MARK: OMM

    /// Throws only when the body is not a JSON array.
    public static func parseOMMJSON(_ data: Data) throws -> Result {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let snippet = String(decoding: data.prefix(80), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.hasPrefix("<") {
                throw ParseError(message: "The server returned a web page, not element data: \(snippet)")
            }
            throw ParseError(message: "The response is not element data: \(snippet)")
        }
        guard let rows = object as? [Any] else {
            throw ParseError(message: "The response is JSON but not a list of element sets.")
        }
        return build(rows: rows.map { $0 as? [String: Any] })
    }

    public static func parseOMMCSV(_ text: String) -> Result {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let headerLine = lines.first else { return Result(elements: [], rejected: []) }
        let header = splitCSV(headerLine).map { $0.trimmingCharacters(in: .whitespaces) }
        guard header.contains("MEAN_MOTION"), header.contains("NORAD_CAT_ID") else {
            return Result(elements: [], rejected: [Rejection(position: 0, reason: "not an OMM CSV: the header has no MEAN_MOTION and NORAD_CAT_ID columns")])
        }
        let rows: [[String: Any]?] = lines.dropFirst().map { line in
            let fields = splitCSV(line)
            var row: [String: Any] = [:]
            for (index, key) in header.enumerated() where index < fields.count { row[key] = fields[index] }
            return row
        }
        return build(rows: rows)
    }

    private static func build(rows: [[String: Any]?]) -> Result {
        var kept: [OrbitalElements] = []
        var rejected: [Rejection] = []
        var indexByID: [Int: Int] = [:]
        for (position, row) in rows.enumerated() {
            guard let row else {
                rejected.append(Rejection(position: position, reason: "row is not an object"))
                continue
            }
            switch element(fromOMM: row) {
            case let .success(candidate):
                if let existing = indexByID[candidate.noradID] {
                    if candidate.epoch > kept[existing].epoch { kept[existing] = candidate }
                } else {
                    indexByID[candidate.noradID] = kept.count
                    kept.append(candidate)
                }
            case let .failure(error):
                rejected.append(Rejection(position: position, reason: error.message))
            }
        }
        return Result(elements: kept, rejected: rejected)
    }

    private static func element(fromOMM row: [String: Any]) -> Swift.Result<OrbitalElements, ParseError> {
        func fail(_ message: String) -> Swift.Result<OrbitalElements, ParseError> { .failure(ParseError(message: message)) }
        func number(_ key: String) -> Double?? {
            guard let value = row[key], !(value is NSNull) else { return .some(nil) }
            if let n = value as? NSNumber { return .some(n.doubleValue) }
            if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)).map { .some($0) } ?? nil }
            return nil
        }
        func required(_ key: String) -> Result2 {
            switch number(key) {
            case .none: return .bad("\(key) is not a number")
            case .some(.none): return .bad("missing \(key)")
            case let .some(.some(v)): return v.isFinite ? .value(v) : .bad("\(key) is not finite")
            }
        }
        func optional(_ key: String) -> Result2 {
            switch number(key) {
            case .none: return .bad("\(key) is not a number")
            case .some(.none): return .value(0)
            case let .some(.some(v)): return v.isFinite ? .value(v) : .bad("\(key) is not finite")
            }
        }

        var idValue: Int?
        if let n = row["NORAD_CAT_ID"] as? NSNumber, n.doubleValue == n.doubleValue.rounded() { idValue = n.intValue }
        if let s = row["NORAD_CAT_ID"] as? String { idValue = Int(s.trimmingCharacters(in: .whitespaces)) }
        guard let noradID = idValue, noradID > 0 else { return fail("missing or invalid NORAD_CAT_ID") }
        guard let epochText = row["EPOCH"] as? String, let epoch = parseEpoch(epochText) else {
            return fail("missing or unreadable EPOCH")
        }

        var values: [String: Double] = [:]
        for key in ["MEAN_MOTION", "ECCENTRICITY", "INCLINATION", "RA_OF_ASC_NODE", "ARG_OF_PERICENTER", "MEAN_ANOMALY", "BSTAR"] {
            switch required(key) {
            case let .value(v): values[key] = v
            case let .bad(message): return fail(message)
            }
        }
        for key in ["MEAN_MOTION_DOT", "MEAN_MOTION_DDOT"] {
            switch optional(key) {
            case let .value(v): values[key] = v
            case let .bad(message): return fail(message)
            }
        }

        let eccentricity = values["ECCENTRICITY"]!
        guard (0..<1).contains(eccentricity) else { return fail("eccentricity \(eccentricity) is outside 0 to 1") }
        guard values["MEAN_MOTION"]! > 0 else { return fail("mean motion is not positive") }
        guard (0...180).contains(values["INCLINATION"]!) else { return fail("inclination is outside 0 to 180 degrees") }

        let name = (row["OBJECT_NAME"] as? String)?.trimmingCharacters(in: .whitespaces)
        return .success(OrbitalElements(
            name: name?.isEmpty == false ? name! : "NORAD \(noradID)",
            noradID: noradID, epoch: epoch,
            inclinationDegrees: values["INCLINATION"]!, raanDegrees: values["RA_OF_ASC_NODE"]!,
            eccentricity: eccentricity, argumentOfPerigeeDegrees: values["ARG_OF_PERICENTER"]!,
            meanAnomalyDegrees: values["MEAN_ANOMALY"]!, meanMotionRevsPerDay: values["MEAN_MOTION"]!,
            bstar: values["BSTAR"]!, meanMotionDot: values["MEAN_MOTION_DOT"]!,
            meanMotionDDot: values["MEAN_MOTION_DDOT"]!))
    }

    private enum Result2 {
        case value(Double)
        case bad(String)
    }

    /// "2026-10-05T14:52:43.642848" (no zone: UTC), also with a trailing Z or +00:00.
    static func parseEpoch(_ text: String) -> Date? {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasSuffix("Z") { body.removeLast() } else if body.hasSuffix("+00:00") { body.removeLast(6) }
        let halves = body.split(whereSeparator: { $0 == "T" || $0 == " " })
        guard halves.count == 2 else { return nil }
        let dateParts = halves[0].split(separator: "-").compactMap { Int($0) }
        let timeParts = halves[1].split(separator: ":", omittingEmptySubsequences: false)
        guard dateParts.count == 3, timeParts.count == 3,
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) else { return nil }
        let secondParts = timeParts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let second = Int(secondParts[0]) else { return nil }
        var fraction = 0.0
        if secondParts.count == 2 {
            guard secondParts[1].allSatisfy({ $0.isNumber }), let f = Double("0." + secondParts[1]) else { return nil }
            fraction = f
        }
        let (year, month, day) = (dateParts[0], dateParts[1], dateParts[2])
        let calendarOK = (1...12).contains(month) && (1...31).contains(day)
        let clockOK = (0...23).contains(hour) && (0...59).contains(minute) && (0...60).contains(second)
        guard calendarOK, clockOK else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second) + fraction)
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var characters = line.makeIterator()
        var pending: Character? = characters.next()
        while let c = pending {
            pending = characters.next()
            if quoted {
                if c == "\"" {
                    if pending == "\"" { current.append("\""); pending = characters.next() } else { quoted = false }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        fields.append(current)
        return fields
    }

    // MARK: TLE

    /// Fixed-column TLE parsing with the mod-10 checksum checked on both lines (a TLE with a wrong checksum has been
    /// damaged or typed by hand). Two-line and three-line (name above, optionally "0 NAME") sets are both accepted.
    public static func parseTLE(_ text: String) -> Result {
        let lines: [String] = text.split(omittingEmptySubsequences: true) { $0.isNewline }.map { trimTrailingSpaces(String($0)) }
        func isLine1(_ s: String) -> Bool { s.hasPrefix("1 ") }
        func isLine2(_ s: String) -> Bool { s.hasPrefix("2 ") }

        var kept: [OrbitalElements] = []
        var rejected: [Rejection] = []
        var setIndex = 0
        var i = 0
        while i < lines.count {
            guard isLine1(lines[i]) else { i += 1; continue }
            var name: String?
            if i > 0, !isLine1(lines[i - 1]), !isLine2(lines[i - 1]) {
                name = lines[i - 1].trimmingCharacters(in: .whitespaces)
            }
            guard i + 1 < lines.count, isLine2(lines[i + 1]) else {
                rejected.append(Rejection(position: setIndex, reason: "line 1 has no line 2 after it"))
                setIndex += 1
                i += 1
                continue
            }
            switch element(line1: lines[i], line2: lines[i + 1], name: name) {
            case let .success(candidate): kept.append(candidate)
            case let .failure(error): rejected.append(Rejection(position: setIndex, reason: error.message))
            }
            setIndex += 1
            i += 2
        }
        return Result(elements: kept, rejected: rejected)
    }

    private static func trimTrailingSpaces(_ line: String) -> String {
        var text = line
        while text.last == " " || text.last == "\r" { text.removeLast() }
        return text
    }

    private static func element(line1: String, line2: String, name: String?) -> Swift.Result<OrbitalElements, ParseError> {
        func fail(_ message: String) -> Swift.Result<OrbitalElements, ParseError> { .failure(ParseError(message: message)) }
        let a = Array(line1), b = Array(line2)
        guard a.count >= 69, b.count >= 69 else { return fail("a TLE line is shorter than 69 characters") }
        guard checksumMatches(a) else { return fail("line 1 checksum is wrong") }
        guard checksumMatches(b) else { return fail("line 2 checksum is wrong") }
        func field(_ chars: [Character], _ range: Range<Int>) -> String {
            String(chars[range]).trimmingCharacters(in: .whitespaces)
        }
        guard let noradID = Int(field(a, 2..<7)), noradID > 0 else {
            return fail("catalog number is not numeric (Alpha-5 numbers are not supported)")
        }
        guard Int(field(b, 2..<7)) == noradID else { return fail("the two lines name different satellites") }

        guard let yy = Int(field(a, 18..<20)), let day = Double(field(a, 20..<32)), (1..<367).contains(day) else {
            return fail("epoch is unreadable")
        }
        let year = yy < 57 ? 2000 + yy : 1900 + yy
        let epoch = Date(timeIntervalSince1970: Double(daysFromCivil(year: year, month: 1, day: 1)) * 86_400 + (day - 1) * 86_400)

        guard let ndot = Double(field(a, 33..<43)), let nddot = impliedDecimal(field(a, 44..<52)),
              let bstar = impliedDecimal(field(a, 53..<61)),
              let inclination = Double(field(b, 8..<16)), let raan = Double(field(b, 17..<25)),
              let eccentricity = Double("0." + field(b, 26..<33)), let argument = Double(field(b, 34..<42)),
              let anomaly = Double(field(b, 43..<51)), let motion = Double(field(b, 52..<63)) else {
            return fail("a numeric field is unreadable")
        }
        guard motion > 0, (0...180).contains(inclination) else { return fail("mean motion or inclination is out of range") }
        let label = name.map { $0.hasPrefix("0 ") ? String($0.dropFirst(2)) : $0 }
        return .success(OrbitalElements(
            name: label?.isEmpty == false ? label! : "NORAD \(noradID)", noradID: noradID, epoch: epoch,
            inclinationDegrees: inclination, raanDegrees: raan, eccentricity: eccentricity,
            argumentOfPerigeeDegrees: argument, meanAnomalyDegrees: anomaly, meanMotionRevsPerDay: motion,
            bstar: bstar, meanMotionDot: ndot, meanMotionDDot: nddot))
    }

    /// The TLE's "assumed decimal point" fields: " 28098-4" is 0.28098e-4, "-11606-4" is -0.11606e-4.
    private static func impliedDecimal(_ text: String) -> Double? {
        guard text.count >= 3, let exponent = Int(text.suffix(2)) else { return nil }
        var mantissa = String(text.dropLast(2))
        var sign = 1.0
        if mantissa.hasPrefix("-") { sign = -1; mantissa.removeFirst() } else if mantissa.hasPrefix("+") { mantissa.removeFirst() }
        guard !mantissa.isEmpty, mantissa.allSatisfy({ $0.isNumber }), let digits = Double("0." + mantissa) else { return nil }
        return sign * digits * pow(10, Double(exponent))
    }

    private static func checksumMatches(_ line: [Character]) -> Bool {
        var total = 0
        for c in line[0..<68] {
            if let d = c.wholeNumberValue, c.isASCII { total += d } else if c == "-" { total += 1 }
        }
        return line[68].wholeNumberValue == total % 10
    }
}

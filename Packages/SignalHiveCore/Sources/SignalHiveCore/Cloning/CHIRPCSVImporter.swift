import Foundation

/// Reads CHIRP-compatible CSV: what CHIRP exports and what `CHIRPCSVExporter` writes. Columns are found by their header
/// names (CHIRP's order varies by radio), so extra or missing columns are fine, and a bad row is skipped and reported,
/// never fatal.
public enum CHIRPCSVImporter {
    public struct Result: Equatable, Sendable {
        public var channels: [CodeplugChannel]
        /// Rows that could not be read, as "line 7: ..." messages.
        public var skipped: [String]
    }

    public static func parse(_ csv: String) -> Result {
        let rows = records(in: csv)
        guard let headerRow = rows.first else { return Result(channels: [], skipped: []) }
        var column: [String: Int] = [:]
        for (index, name) in headerRow.enumerated() { column[name.trimmingCharacters(in: .whitespaces).lowercased()] = index }
        guard column["frequency"] != nil else {
            return Result(channels: [], skipped: ["This does not look like a CHIRP CSV: there is no Frequency column."])
        }

        var channels: [CodeplugChannel] = []
        var skipped: [String] = []
        for (offset, fields) in rows.dropFirst().enumerated() {
            let line = offset + 2
            func text(_ name: String) -> String {
                guard let index = column[name], index < fields.count else { return "" }
                return fields[index].trimmingCharacters(in: .whitespaces)
            }
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            guard let mhz = Double(text("frequency")), mhz > 0 else {
                skipped.append("line \(line): no usable frequency (\"\(text("frequency"))\")")
                continue
            }

            var offsetHz = 0.0
            if let offsetMHz = Double(text("offset")) {
                switch text("duplex") {
                case "+": offsetHz = offsetMHz * 1_000_000
                case "-": offsetHz = -offsetMHz * 1_000_000
                default: offsetHz = 0
                }
            }

            var ctcss = 0.0
            var dtcs = 0
            switch text("tone") {
            case "Tone": ctcss = Double(text("rtonefreq")) ?? 0                    // transmit tone only
            case "TSQL": ctcss = Double(text("ctonefreq")) ?? Double(text("rtonefreq")) ?? 0
            case "DTCS": dtcs = Int(text("dtcscode")) ?? 0
            default: break
            }

            let mode: ChannelMode
            switch text("mode").uppercased() {
            case "FM", "WFM": mode = .fm
            case "NFM": mode = .nfm
            case "AM": mode = .am
            case "DMR": mode = .dmr
            case "P25": mode = .p25
            case "DSTAR", "DV", "D-STAR": mode = .dstar
            default: mode = .nfm
            }

            let power = Int(text("power").uppercased().replacingOccurrences(of: "W", with: "").split(separator: ".").first ?? "") ?? 5
            channels.append(CodeplugChannel(
                name: text("name"), frequencyHz: (mhz * 1_000_000).rounded(), offsetHz: offsetHz.rounded(), mode: mode,
                ctcssToneHz: ctcss, dtcsCode: dtcs, powerWatts: max(0, power), notes: text("comment")))
        }
        return Result(channels: channels, skipped: skipped)
    }

    /// Splits CSV text into records of fields, honouring quotes (a quoted field may hold commas, doubled quotes, and
    /// line breaks).
    static func records(in text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var previousWasQuote = false
        for character in text {
            if inQuotes {
                if character == "\"" {
                    if previousWasQuote {                                  // "" inside quotes is a literal quote
                        field.append("\"")
                        previousWasQuote = false
                    } else {
                        previousWasQuote = true
                    }
                } else {
                    if previousWasQuote {                                  // the quote before this character closed the field
                        inQuotes = false
                        previousWasQuote = false
                        handle(character, &field, &row, &rows, &inQuotes)
                    } else {
                        field.append(character)
                    }
                }
            } else {
                handle(character, &field, &row, &rows, &inQuotes)
            }
        }
        if previousWasQuote { inQuotes = false }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func handle(_ character: Character, _ field: inout String, _ row: inout [String], _ rows: inout [[String]],
                               _ inQuotes: inout Bool) {
        switch character {
        case "\"":
            inQuotes = true
        case ",":
            row.append(field)
            field = ""
        case "\n", "\r\n", "\r":
            row.append(field)
            field = ""
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        default:
            field.append(character)
        }
    }
}

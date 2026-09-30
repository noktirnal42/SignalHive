import Foundation

// MARK: - CHIRP-compatible CSV export

public enum CHIRPCSVExporter {

    static let header = [
        "Location", "Name", "Frequency", "Duplex", "Offset", "Tone",
        "rToneFreq", "cToneFreq", "DtcsCode", "DtcsPolarity", "RxDtcsCode",
        "CrossMode", "Mode", "Power", "Skip", "Comment", "URCALL", "RPT1CALL",
        "RPT2CALL", "DVCODE",
    ]

    public static func csv(for channels: [CodeplugChannel]) throws -> String {
        var lines = [header.joined(separator: ",")]
        for (index, channel) in channels.enumerated() {
            lines.append(row(index: index, channel: channel))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func row(index: Int, channel: CodeplugChannel) -> String {
        let name = escape(channel.name)
        let freq = String(format: "%.6f", channel.frequencyHz / 1_000_000)
        let duplex: String
        let offset: String
        if channel.offsetHz == 0 {
            duplex = "off"
            offset = "0.000000"
        } else if channel.offsetHz > 0 {
            duplex = "+"
            offset = String(format: "%.6f", channel.offsetHz / 1_000_000)
        } else {
            duplex = "-"
            offset = String(format: "%.6f", -channel.offsetHz / 1_000_000)
        }

        let (toneKind, rTone, cTone, dtcs): (String, String, String, String)
        if channel.dtcsCode != 0 {
            toneKind = "DTCS"
            rTone = "88.5"
            cTone = "88.5"
            dtcs = String(format: "%03d", channel.dtcsCode)
        } else if channel.ctcssToneHz > 0 {
            toneKind = "Tone"
            rTone = String(format: "%.1f", channel.ctcssToneHz)
            cTone = String(format: "%.1f", channel.ctcssToneHz)
            dtcs = "023"
        } else {
            toneKind = ""
            rTone = "88.5"
            cTone = "88.5"
            dtcs = "023"
        }

        let mode: String
        switch channel.mode {
        case .fm: mode = "FM"
        case .nfm: mode = "NFM"
        case .am: mode = "AM"
        case .dmr: mode = "DMR"
        case .p25: mode = "P25"
        case .dstar: mode = "DSTAR"
        }
        let power = String(format: "%.1fW", Double(channel.powerWatts))
        let comment = escape(channel.notes.isEmpty ? channel.sourceCallSign : channel.notes)

        return [
            String(index), name, freq, duplex, offset, toneKind, rTone, cTone,
            dtcs, "NN", "023", "Tone->Tone", mode, power, "", comment, "", "", "", "",
        ].joined(separator: ",")
    }

    static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Parse a CHIRP CSV file back into channels (import path). Rows that cannot be read are skipped; use
    /// `CHIRPCSVImporter.parse` to learn which.
    public static func parse(csv: String) -> [CodeplugChannel] {
        CHIRPCSVImporter.parse(csv).channels
    }

    static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let ch = iterator.next() {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }
}

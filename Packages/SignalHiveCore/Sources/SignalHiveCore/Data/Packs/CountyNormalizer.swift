import Foundation

// MARK: - County normalization
//
// FCC county strings are free text: "ST. LOUIS", "ST LOUIS COUNTY", "De Kalb".
// `key` folds those variants into one canonical uppercase key so the same county
// from different licenses lands in one bucket.

public enum CountyNormalizer {

    private static let dropTrailing: Set<String> = ["COUNTY", "PARISH", "BOROUGH", "MUNICIPIO", "MUNICIPALITY"]

    private static let aliases: [String: String] = [
        "DE KALB": "DEKALB",
        "DE SOTO": "DESOTO",
        "DE WITT": "DEWITT",
        "DU PAGE": "DUPAGE",
    ]

    public static func key(_ raw: String) -> String {
        var text = raw.uppercased()
        for character in ["(", ")"] { text = text.replacingOccurrences(of: character, with: " ") }
        for character in [".", "'", "\u{2019}", ","] { text = text.replacingOccurrences(of: character, with: "") }

        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        tokens = tokens.map { token in
            switch token {
            case "ST": return "SAINT"
            case "STE": return "SAINTE"
            default: return token
            }
        }
        if tokens.count > 2, tokens.suffix(2) == ["CENSUS", "AREA"] {
            tokens.removeLast(2)
        } else if tokens.count > 1, let last = tokens.last, dropTrailing.contains(last) {
            tokens.removeLast()
        }

        let joined = tokens.joined(separator: " ")
        return aliases[joined] ?? joined
    }

    /// Human-readable name with the local naming convention (parish, borough, independent city).
    public static func displayName(key: String, stateCode: String) -> String {
        let words = key.split(separator: " ").map { word -> String in
            let word = String(word)
            switch word {
            case "SAINT": return "St."
            case "SAINTE": return "Ste."
            default: return capitalize(word)
            }
        }
        let name = words.joined(separator: " ")
        switch stateCode {
        case "LA": return name + " Parish"
        case "AK", "PR": return name
        default:
            return key.hasSuffix(" CITY") ? name : name + " County"
        }
    }

    /// State-scoped identifier, or nil when the FCC row has no county.
    public static func countyID(raw: String, stateCode: String) -> String? {
        let normalized = key(raw)
        return normalized.isEmpty ? nil : "\(stateCode):\(normalized)"
    }

    private static func capitalize(_ word: String) -> String {
        word.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
            let part = String(part)
            if part.hasPrefix("MC"), part.count > 3 {
                return "Mc" + part.dropFirst(2).lowercased().capitalized
            }
            return part.lowercased().capitalized
        }.joined(separator: "-")
    }
}

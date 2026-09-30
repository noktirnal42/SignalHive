import Foundation
import GRDB

// MARK: - Geographic entities

public struct USState: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var code: String
    public var name: String
    public var id: String { code }
    public static let databaseTableName = "states"

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public struct USCounty: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var stateCode: String
    public var county: String
    public var id: String { "\(stateCode)-\(county)" }
    public static let databaseTableName = "counties"

    public init(stateCode: String, county: String) {
        self.stateCode = stateCode
        self.county = county
    }
}

// MARK: - ULS entities

public struct ULSEntity: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var uid: Int64
    public var callSign: String
    public var entityType: String
    public var name: String
    public var city: String
    public var state: String
    public var zipCode: String
    public var id: Int64 { uid }
    public static let databaseTableName = "entities"

    public var displayName: String {
        name.isEmpty ? callSign : name
    }
}

public struct ULSLicense: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var uid: Int64
    public var callSign: String
    public var licenseStatus: String
    public var radioServiceCode: String
    public var grantDate: String
    public var expiredDate: String
    public var id: Int64 { uid }
    public static let databaseTableName = "licenses"

    public var isExpired: Bool { licenseStatus != "A" }
    public var serviceName: String { RadioServiceCatalog.name(for: radioServiceCode) }
}

public struct ULSFrequency: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var uid: Int64
    public var callSign: String
    public var locationNumber: Int
    public var frequencyHz: Double
    public var upperBandHz: Double
    public var isCarrier: Bool
    public var classStationCode: String
    public var powerOutput: String
    public var status: String
    public var id: String { "\(uid)-\(locationNumber)-\(frequencyHz)" }
    public static let databaseTableName = "frequencies"

    public var displayMHz: String {
        let mhz = frequencyHz / 1_000_000
        if frequencyHz >= 1_000_000_000 { return String(format: "%.4f GHz", mhz / 1000) }
        return String(format: "%.5f MHz", mhz)
    }
}

public struct ULSLocation: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var uid: Int64
    public var locationNumber: Int
    public var city: String
    public var county: String
    public var state: String
    public var latitude: Double
    public var longitude: Double
    public var id: String { "\(uid)-\(locationNumber)" }
    public static let databaseTableName = "locations"

    public var coordinateDescription: String {
        guard latitude != 0 || longitude != 0 else { return "" }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }
}

public struct ULSEmission: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var uid: Int64
    public var frequencyHz: Double
    public var emissionCode: String
    public static let databaseTableName = "emissions"
}

public struct ULSComment: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var uid: Int64
    public var callSign: String
    public var descriptionText: String
    public static let databaseTableName = "comments"
}

// MARK: - Trunked systems (OpenMHz)

/// A trunked radio system listed by OpenMHz (a community site that records and shares public-safety calls).
public struct TrunkedSystem: Codable, Identifiable, Hashable, Sendable {
    /// OpenMHz's short identifier, such as "wmata" or "sccsd".
    public var shortName: String
    public var name: String
    /// "p25", "smartnet", "dmr" and so on, as OpenMHz reports it.
    public var systemType: String
    public var city: String
    public var county: String
    public var state: String
    public var country: String
    public var details: String
    /// Average calls per hour, as OpenMHz reports it.
    public var callsPerHour: Double
    /// Listeners connected to the system right now.
    public var listeners: Int
    public var isActive: Bool
    public var lastActive: Date?
    public var id: String { shortName }

    public init(shortName: String, name: String, systemType: String = "", city: String = "", county: String = "",
                state: String = "", country: String = "", details: String = "", callsPerHour: Double = 0,
                listeners: Int = 0, isActive: Bool = true, lastActive: Date? = nil) {
        self.shortName = shortName
        self.name = name
        self.systemType = systemType
        self.city = city
        self.county = county
        self.state = state
        self.country = country
        self.details = details
        self.callsPerHour = callsPerHour
        self.listeners = listeners
        self.isActive = isActive
        self.lastActive = lastActive
    }

    /// "City, County, ST" with whatever parts are known.
    public var location: String {
        [city, county, state].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// "P25", "SmartNet" and so on, for display.
    public var typeLabel: String {
        switch systemType.lowercased() {
        case "p25": return "P25"
        case "smartnet": return "SmartNet"
        case "dmr": return "DMR"
        case "edacs": return "EDACS"
        case "nxdn": return "NXDN"
        case "": return ""
        default: return systemType
        }
    }
}

public struct TrunkedTalkgroup: Codable, Identifiable, Hashable, Sendable {
    public var systemShortName: String
    /// The decimal talkgroup ID.
    public var code: Int
    /// The short name a scanner shows.
    public var alphaTag: String
    public var descriptionText: String
    /// The service tag ("Law Dispatch", "Fire-Tac" ...) when the source provides one.
    public var tag: String
    public var group: String
    public var callCount: Int
    public var id: String { "\(systemShortName)-\(code)" }

    public init(systemShortName: String, code: Int, alphaTag: String, descriptionText: String, tag: String = "",
                group: String = "", callCount: Int = 0) {
        self.systemShortName = systemShortName
        self.code = code
        self.alphaTag = alphaTag
        self.descriptionText = descriptionText
        self.tag = tag
        self.group = group
        self.callCount = callCount
    }

    /// What to call it: the alpha tag, else the description, else the number.
    public var displayName: String {
        if !alphaTag.isEmpty { return alphaTag }
        if !descriptionText.isEmpty { return descriptionText }
        return "TG \(code)"
    }

    public var category: TalkgroupCategory { TalkgroupCategory.classify(self) }
}

/// The kind of traffic a talkgroup carries, judged from its tag, group and name.
public enum TalkgroupCategory: String, CaseIterable, Codable, Sendable {
    case law
    case fire
    case ems
    case publicWorks
    case transit
    case schools
    case aviation
    case federal
    case utilities
    case corrections
    case hospital
    case interop
    case other

    public var displayName: String {
        switch self {
        case .law: return "Law enforcement"
        case .fire: return "Fire"
        case .ems: return "EMS"
        case .publicWorks: return "Public works"
        case .transit: return "Transportation"
        case .schools: return "Schools"
        case .aviation: return "Airport"
        case .federal: return "Federal"
        case .utilities: return "Utilities"
        case .corrections: return "Corrections"
        case .hospital: return "Hospital"
        case .interop: return "Interoperability"
        case .other: return "Other"
        }
    }

    /// An SF Symbol name.
    public var symbolName: String {
        switch self {
        case .law: return "shield.lefthalf.filled"
        case .fire: return "flame"
        case .ems: return "cross.case"
        case .publicWorks: return "wrench.and.screwdriver"
        case .transit: return "bus"
        case .schools: return "graduationcap"
        case .aviation: return "airplane"
        case .federal: return "building.columns"
        case .utilities: return "bolt"
        case .corrections: return "lock"
        case .hospital: return "cross"
        case .interop: return "arrow.triangle.merge"
        case .other: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Words that put a talkgroup in a category, most specific first. A word must match a whole word of the text; a word
    /// ending in `*` matches any word that starts with it ("polic*" matches "police" and "policing" but not "impolite");
    /// several words match as a phrase.
    private static let keywords: [(TalkgroupCategory, [String])] = [
        (.hospital, ["hospital*", "medical center", "med ctr", "clinic*"]),
        (.ems, ["ems", "medic*", "ambulance*", "paramedic*", "rescue squad"]),
        (.fire, ["fire*", "engine", "ladder", "hazmat", "fd"]),
        (.law, ["law", "polic*", "sheriff*", "pd", "patrol*", "trooper*", "marshal*", "deputy", "constable*", "detective*", "swat", "k9"]),
        (.corrections, ["correction*", "jail", "prison*", "detention", "inmate*"]),
        (.federal, ["federal", "fbi", "dea", "atf", "dhs", "border", "secret service", "usss", "cbp"]),
        (.aviation, ["airport*", "aviation", "airfield", "tower", "arff"]),
        (.schools, ["school*", "isd", "universit*", "college*", "campus"]),
        (.transit, ["transit", "transportation", "metro*", "railroad", "amtrak", "dot", "bus", "train*", "ferry", "rail"]),
        (.utilities, ["utility", "utilities", "electric*", "power", "gas", "water", "sewer*", "telephone"]),
        (.publicWorks, ["public works", "street*", "highway*", "road*", "park*", "sanitation", "dpw", "maintenance", "facilities", "fleet"]),
        (.interop, ["interop*", "mutual aid", "statewide", "common", "calling", "tac"]),
    ]

    private static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func matches(_ keyword: String, in tokens: [String]) -> Bool {
        if keyword.hasSuffix("*") {
            let stem = String(keyword.dropLast())
            return tokens.contains { $0.hasPrefix(stem) }
        }
        let phrase = keyword.split(separator: " ").map(String.init)
        if phrase.count == 1 { return tokens.contains(phrase[0]) }
        guard tokens.count >= phrase.count else { return false }
        for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<(start + phrase.count)]) == phrase {
            return true
        }
        return false
    }

    static func category(forText text: String) -> TalkgroupCategory? {
        let tokens = words(in: text)
        guard !tokens.isEmpty else { return nil }
        for (category, list) in keywords where list.contains(where: { matches($0, in: tokens) }) {
            return category
        }
        return nil
    }

    /// Classifies by the service tag and group first (they are meant for this), then the name and description.
    public static func classify(_ talkgroup: TrunkedTalkgroup) -> TalkgroupCategory {
        category(forText: talkgroup.tag)
            ?? category(forText: talkgroup.group)
            ?? category(forText: talkgroup.alphaTag + " " + talkgroup.descriptionText)
            ?? .other
    }
}

// MARK: - Radio service codes

public enum RadioServiceCatalog {
    public static let names: [String: String] = [
        "AC": "Aircraft (Part 87)",
        "AF": "Aviation Frequency",
        "AL": "Aeronautical Enroute",
        "CL": "Cellular (Part 22)",
        "CW": "Public Safety Wireless Mic",
        "HA": "GMRS (Part 95)",
        "HV": "Broadcast Auxiliary",
        "IA": "Industrial/Business",
        "IG": "Industrial/Business (Part 90)",
        "MA": "Marine (Part 80)",
        "ML": "Marine Utility",
        "MV": "Marine VHF",
        "PB": "Paging (Part 22)",
        "PC": "Public Safety Pool, Conventional",
        "PW": "Public Safety Pool, Trunked",
        "PE": "Police Conventional",
        "PS": "Public Safety Pool",
        "YP": "Industrial/Business, Trunked",
        "YW": "Industrial/Business, Conventional",
        "YH": "SMR, Conventional",
        "ZP": "Part 90 Trunked",
        "ZT": "Part 90 Conventional",
        "ZV": "VHF/UHF Business",
        "AM": "Amateur",
        "CO": "Coast/Marine",
        "SH": "Ship (Part 80)",
        "FRC": "Fixed Microwave",
    ]

    public static func name(for code: String) -> String {
        names[code] ?? code
    }
}

public enum LicenseStatusCatalog {
    public static let names: [String: String] = [
        "A": "Active",
        "C": "Cancelled",
        "E": "Expired",
        "P": "Pending",
        "T": "Terminated",
        "X": "Terminated",
        "I": "Inactive",
    ]

    public static func name(for code: String) -> String {
        names[code] ?? code
    }
}

// MARK: - Attribution

public enum DataAttribution {
    public static let fccNotice = "This product uses the FCC Data API but is not endorsed or certified by the FCC."
    public static let sources = [
        "FCC Universal Licensing System weekly database dumps (public domain)",
        "FCC Area & Census API (geo.fcc.gov)",
        "OpenMHz community trunked-system data (openmhz.com)",
    ]
}

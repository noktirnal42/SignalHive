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

public struct TrunkedSystem: Codable, Identifiable, Hashable, Sendable {
    public var shortName: String
    public var name: String
    public var talkgroupCount: Int
    public var callCount: Int
    public var lat: Double?
    public var lon: Double?
    public var id: String { shortName }
}

public struct TrunkedTalkgroup: Codable, Identifiable, Hashable, Sendable {
    public var systemShortName: String
    public var code: Int
    public var alphaTag: String
    public var descriptionText: String
    public var callCount: Int
    public var id: String { "\(systemShortName)-\(code)" }
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

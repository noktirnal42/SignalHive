import Foundation

// MARK: - Browse models
//
// UI-agnostic value types shared by the real (pack-backed) and mock data sources.

public struct CountyID: Hashable, Sendable, Codable {
    public var stateCode: String
    /// `"<ST>:<NORMALIZED NAME>"`; `"<ST>:?"` is the bucket for sites without a county.
    public var id: String

    public init(stateCode: String, id: String) {
        self.stateCode = stateCode
        self.id = id
    }

    public var isUnknownBucket: Bool { id.hasSuffix(":?") }
}

public struct CountySummary: Identifiable, Hashable, Sendable {
    public var id: CountyID
    public var name: String
    public var licenseCount: Int

    public init(id: CountyID, name: String, licenseCount: Int) {
        self.id = id
        self.name = name
        self.licenseCount = licenseCount
    }
}

public enum PackStatus: Hashable, Sendable {
    case notInstalled(sizeBytes: Int64?)
    case downloading(progress: Double)
    case verifying
    case installed(snapshot: String)
    case failed(reason: String)
}

public struct StateAvailability: Identifiable, Hashable, Sendable {
    public var code: String
    public var name: String
    public var status: PackStatus
    public var id: String { code }

    public init(code: String, name: String, status: PackStatus) {
        self.code = code
        self.name = name
        self.status = status
    }
}

public struct LicenseFilter: Hashable, Sendable {
    public var serviceCodes: Set<String>
    public var text: String?

    public init(serviceCodes: Set<String> = [], text: String? = nil) {
        self.serviceCodes = serviceCodes
        self.text = text
    }

    public static let none = LicenseFilter()
}

public struct LicenseSummary: Identifiable, Hashable, Sendable {
    public var uid: Int64
    public var callSign: String
    public var licenseeName: String
    public var serviceCode: String
    public var serviceName: String
    public var city: String
    public var frequencyCount: Int
    public var modeHints: [ModeHint]
    public var id: Int64 { uid }

    public init(uid: Int64, callSign: String, licenseeName: String, serviceCode: String, serviceName: String,
                city: String, frequencyCount: Int, modeHints: [ModeHint]) {
        self.uid = uid
        self.callSign = callSign
        self.licenseeName = licenseeName
        self.serviceCode = serviceCode
        self.serviceName = serviceName
        self.city = city
        self.frequencyCount = frequencyCount
        self.modeHints = modeHints
    }
}

public struct FrequencyRecord: Identifiable, Hashable, Sendable {
    public var uid: Int64
    public var locationNumber: Int
    public var frequencyHz: Double
    public var upperBandHz: Double?
    public var classStationCode: String
    public var powerW: Double?
    public var modeHints: [ModeHint]
    public var bandwidthHz: Double?
    public var id: String { "\(uid)-\(locationNumber)-\(frequencyHz)-\(classStationCode)" }

    public init(uid: Int64, locationNumber: Int, frequencyHz: Double, upperBandHz: Double? = nil,
                classStationCode: String = "", powerW: Double? = nil, modeHints: [ModeHint] = [],
                bandwidthHz: Double? = nil) {
        self.uid = uid
        self.locationNumber = locationNumber
        self.frequencyHz = frequencyHz
        self.upperBandHz = upperBandHz
        self.classStationCode = classStationCode
        self.powerW = powerW
        self.modeHints = modeHints
        self.bandwidthHz = bandwidthHz
    }

    public var displayMHz: String {
        let mhz = frequencyHz / 1_000_000
        if frequencyHz >= 1_000_000_000 { return String(format: "%.4f GHz", mhz / 1000) }
        return String(format: "%.5f MHz", mhz)
    }
}

public struct SiteRecord: Identifiable, Hashable, Sendable {
    public var uid: Int64
    public var locationNumber: Int
    public var city: String
    public var countyName: String?
    public var stateCode: String
    public var latitude: Double?
    public var longitude: Double?
    public var id: String { "\(uid)-\(locationNumber)" }

    public init(uid: Int64, locationNumber: Int, city: String, countyName: String?, stateCode: String,
                latitude: Double?, longitude: Double?) {
        self.uid = uid
        self.locationNumber = locationNumber
        self.city = city
        self.countyName = countyName
        self.stateCode = stateCode
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct LicenseDetail: Hashable, Sendable {
    public var summary: LicenseSummary
    public var grantDate: String
    public var expiredDate: String
    public var sites: [SiteRecord]
    public var frequencies: [FrequencyRecord]

    public init(summary: LicenseSummary, grantDate: String, expiredDate: String,
                sites: [SiteRecord], frequencies: [FrequencyRecord]) {
        self.summary = summary
        self.grantDate = grantDate
        self.expiredDate = expiredDate
        self.sites = sites
        self.frequencies = frequencies
    }
}

public enum SearchScope: Sendable {
    case all, callSign, licensee, frequency
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case license, frequency }
    public var kind: Kind
    public var uid: Int64
    public var title: String
    public var subtitle: String
    public var frequencyHz: Double?
    public var id: String { "\(kind.rawValue)-\(uid)-\(frequencyHz ?? 0)" }

    public init(kind: Kind, uid: Int64, title: String, subtitle: String, frequencyHz: Double? = nil) {
        self.kind = kind
        self.uid = uid
        self.title = title
        self.subtitle = subtitle
        self.frequencyHz = frequencyHz
    }
}

public struct Coordinate: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct NearbyFrequency: Identifiable, Hashable, Sendable {
    public var frequency: FrequencyRecord
    public var callSign: String
    public var city: String
    public var distanceKm: Double
    public var id: String { frequency.id }

    public init(frequency: FrequencyRecord, callSign: String, city: String, distanceKm: Double) {
        self.frequency = frequency
        self.callSign = callSign
        self.city = city
        self.distanceKm = distanceKm
    }
}

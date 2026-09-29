import Foundation

// MARK: - ULS pipe-delimited record parser
//
// FCC ULS "public access" weekly dumps ship pipe-delimited .dat files.
// Field 0 is the record type (EN/HD/FR/LO/EM/CO/AM/HS/...), and documented
// column layouts follow the FCC PUBACC table definitions. Parsing is
// tolerant: out-of-bounds fields are treated as empty and malformed lines
// are skipped.

public struct ULSRawRecord {
    public var fields: [String]

    public func field(_ index: Int) -> String {
        guard index >= 0, index < fields.count else { return "" }
        return fields[index].trimmingCharacters(in: .whitespaces)
    }
}

public struct ULSRecordBatch: Sendable {
    public var entities: [ULSEntity]
    public var licenses: [ULSLicense]
    public var frequencies: [ULSFrequency]
    public var locations: [ULSLocation]
    public var emissions: [ULSEmission]
    public var comments: [ULSComment]

    public var count: Int {
        entities.count + licenses.count + frequencies.count + locations.count + emissions.count + comments.count
    }
}

public enum ULSParserError: Error, LocalizedError {
    case emptyTable(String)

    public var errorDescription: String? {
        switch self {
        case let .emptyTable(name):
            return "ULS table file is empty: \(name)"
        }
    }
}

public enum ULSParser {

    // MARK: Entity (EN.dat, 30 columns after record type)

    static func parseEntity(_ r: ULSRawRecord) -> ULSEntity? {
        guard let uid = Int64(r.field(1)) else { return nil }
        return ULSEntity(
            uid: uid,
            callSign: r.field(4),
            entityType: r.field(5),
            name: r.field(7),
            city: r.field(16),
            state: r.field(17),
            zipCode: r.field(18)
        )
    }

    // MARK: License (HD.dat, 59 columns after record type)

    static func parseLicense(_ r: ULSRawRecord) -> ULSLicense? {
        guard let uid = Int64(r.field(1)) else { return nil }
        return ULSLicense(
            uid: uid,
            callSign: r.field(4),
            licenseStatus: r.field(5),
            radioServiceCode: r.field(6),
            grantDate: r.field(7),
            expiredDate: r.field(8)
        )
    }

    // MARK: Frequency (FR.dat, 30 columns after record type)

    static func parseFrequency(_ r: ULSRawRecord) -> ULSFrequency? {
        guard let uid = Int64(r.field(1)) else { return nil }
        guard let mhz = Double(r.field(10)) else { return nil }
        let upper = Double(r.field(11)) ?? 0
        return ULSFrequency(
            uid: uid,
            callSign: r.field(4),
            locationNumber: Int(r.field(6)) ?? 0,
            frequencyHz: mhz * 1_000_000,
            upperBandHz: upper * 1_000_000,
            isCarrier: r.field(12).uppercased() == "Y",
            classStationCode: r.field(8),
            powerOutput: r.field(15),
            status: r.field(19)
        )
    }

    // MARK: Location (LO.dat, 51 columns after record type)

    static func parseLocation(_ r: ULSRawRecord) -> ULSLocation? {
        guard let uid = Int64(r.field(1)) else { return nil }
        let lat = Self.coordinate(
            degrees: r.field(20), minutes: r.field(21), seconds: r.field(22), direction: r.field(23)
        )
        let lon = Self.coordinate(
            degrees: r.field(24), minutes: r.field(25), seconds: r.field(26), direction: r.field(27)
        )
        return ULSLocation(
            uid: uid,
            locationNumber: Int(r.field(8)) ?? 0,
            city: r.field(12),
            county: r.field(13),
            state: r.field(14),
            latitude: lat ?? 0,
            longitude: lon ?? 0
        )
    }

    // MARK: Emission (EM.dat)

    static func parseEmission(_ r: ULSRawRecord) -> ULSEmission? {
        guard let uid = Int64(r.field(1)) else { return nil }
        guard let mhz = Double(r.field(7)) else { return nil }
        return ULSEmission(uid: uid, frequencyHz: mhz * 1_000_000, emissionCode: r.field(9))
    }

    // MARK: Comment (CO.dat)

    static func parseComment(_ r: ULSRawRecord) -> ULSComment? {
        guard let uid = Int64(r.field(1)) else { return nil }
        let text = r.field(5)
        guard !text.isEmpty else { return nil }
        return ULSComment(uid: uid, callSign: r.field(3), descriptionText: text)
    }

    // MARK: DMS → decimal degrees

    static func coordinate(degrees: String, minutes: String, seconds: String, direction: String) -> Double? {
        guard let d = Double(degrees) else { return nil }
        let m = Double(minutes) ?? 0
        let s = Double(seconds) ?? 0
        var value = d + m / 60.0 + s / 3600.0
        let dir = direction.uppercased()
        if dir == "S" || dir == "W" { value = -value }
        return value
    }

    // MARK: Table file parsing

    public static func parseTable(at url: URL) throws -> ULSRecordBatch {
        var batch = ULSRecordBatch(entities: [], licenses: [], frequencies: [], locations: [], emissions: [], comments: [])
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw ULSParserError.emptyTable(url.lastPathComponent) }

        var buffer = [UInt8]()
        buffer.reserveCapacity(1024)

        func flushLine() {
            guard !buffer.isEmpty else { return }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            process(line: line, into: &batch)
        }

        for byte in data {
            if byte == 10 { // \n
                flushLine()
            } else if byte != 13 { // skip \r
                buffer.append(byte)
            }
        }
        flushLine()
        return batch
    }

    static func process(line: String, into batch: inout ULSRecordBatch) {
        guard !line.isEmpty else { return }
        let fields = line.components(separatedBy: "|")
        guard fields.count > 1 else { return }
        let record = ULSRawRecord(fields: fields)

        switch fields[0] {
        case "EN":
            if let e = parseEntity(record) { batch.entities.append(e) }
        case "HD":
            if let l = parseLicense(record) { batch.licenses.append(l) }
        case "FR":
            if let f = parseFrequency(record) { batch.frequencies.append(f) }
        case "LO":
            if let l = parseLocation(record) { batch.locations.append(l) }
        case "EM":
            if let e = parseEmission(record) { batch.emissions.append(e) }
        case "CO":
            if let c = parseComment(record) { batch.comments.append(c) }
        default:
            break
        }
    }
}

// MARK: - ULS services

public enum ULSService: String, Codable, CaseIterable, Identifiable, Sendable {
    case lmPriv = "LMpriv"
    case lmComm = "LMcomm"
    case gmrs = "GMRS"
    case aircraft = "Aircraft"
    case amateur = "Amateur"
    case marine = "Marine"
    case ship = "Ship"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lmPriv: return "Land Mobile — Private/Public Safety"
        case .lmComm: return "Land Mobile — Commercial/Business"
        case .gmrs: return "GMRS"
        case .aircraft: return "Aircraft"
        case .amateur: return "Amateur"
        case .marine: return "Coast/Marine"
        case .ship: return "Ship"
        }
    }

    public var completeZipURL: URL {
        URL(string: "https://data.fcc.gov/download/pub/uls/complete/l_\(rawValue).zip")!
    }

    public var approximateSizeMB: Int {
        switch self {
        case .lmPriv: return 403
        case .lmComm: return 78
        case .gmrs: return 68
        case .aircraft: return 15
        case .amateur: return 188
        case .marine: return 10
        case .ship: return 42
        }
    }
}

// MARK: - US state list (FCC standard)

public enum USStateCatalog {
    public static let states: [(code: String, name: String)] = [
        ("AL", "Alabama"), ("AK", "Alaska"), ("AZ", "Arizona"), ("AR", "Arkansas"),
        ("CA", "California"), ("CO", "Colorado"), ("CT", "Connecticut"), ("DE", "Delaware"),
        ("DC", "District of Columbia"), ("FL", "Florida"), ("GA", "Georgia"), ("HI", "Hawaii"),
        ("ID", "Idaho"), ("IL", "Illinois"), ("IN", "Indiana"), ("IA", "Iowa"),
        ("KS", "Kansas"), ("KY", "Kentucky"), ("LA", "Louisiana"), ("ME", "Maine"),
        ("MD", "Maryland"), ("MA", "Massachusetts"), ("MI", "Michigan"), ("MN", "Minnesota"),
        ("MS", "Mississippi"), ("MO", "Missouri"), ("MT", "Montana"), ("NE", "Nebraska"),
        ("NV", "Nevada"), ("NH", "New Hampshire"), ("NJ", "New Jersey"), ("NM", "New Mexico"),
        ("NY", "New York"), ("NC", "North Carolina"), ("ND", "North Dakota"), ("OH", "Ohio"),
        ("OK", "Oklahoma"), ("OR", "Oregon"), ("PA", "Pennsylvania"), ("RI", "Rhode Island"),
        ("SC", "South Carolina"), ("SD", "South Dakota"), ("TN", "Tennessee"), ("TX", "Texas"),
        ("UT", "Utah"), ("VT", "Vermont"), ("VA", "Virginia"), ("WA", "Washington"),
        ("WV", "West Virginia"), ("WI", "Wisconsin"), ("WY", "Wyoming"),
        ("AS", "American Samoa"), ("GU", "Guam"), ("MP", "Northern Mariana Islands"),
        ("PR", "Puerto Rico"), ("VI", "U.S. Virgin Islands"),
    ]
}

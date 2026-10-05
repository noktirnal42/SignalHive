import Foundation

public enum SatelliteCaptureMode: String, CaseIterable, Sendable, Codable {
    case meteorLRPT = "Meteor LRPT"
    case noaaAPT = "NOAA APT"
    case metopAHRPT = "MetOp AHRPT"

    public var decoderName: String {
        switch self {
        case .meteorLRPT: "LRPTDecoder"
        case .noaaAPT: "APT image renderer"
        case .metopAHRPT: "AHRPT planning only"
        }
    }

    public var productName: String {
        switch self {
        case .meteorLRPT: "MSU-MR composite"
        case .noaaAPT: "APT visible/IR strip"
        case .metopAHRPT: "AHRPT capture plan"
        }
    }
}

public struct SatelliteCaptureRecipe: Identifiable, Equatable, Sendable {
    public var id: String { pass.id + "-" + mode.rawValue }
    public var pass: SatellitePass
    public var mode: SatelliteCaptureMode
    public var downlinkFrequencyHz: Double
    public var sampleRateHz: Double
    public var captureStart: Date
    public var captureEnd: Date
    public var dopplerCorrectionEnabled: Bool
    public var hardwareReady: Bool

    public var captureDuration: TimeInterval { captureEnd.timeIntervalSince(captureStart) }

    public init(pass: SatellitePass, mode: SatelliteCaptureMode, downlinkFrequencyHz: Double, sampleRateHz: Double,
                captureStart: Date, captureEnd: Date, dopplerCorrectionEnabled: Bool = true,
                hardwareReady: Bool = false) {
        self.pass = pass
        self.mode = mode
        self.downlinkFrequencyHz = downlinkFrequencyHz
        self.sampleRateHz = sampleRateHz
        self.captureStart = captureStart
        self.captureEnd = captureEnd
        self.dopplerCorrectionEnabled = dopplerCorrectionEnabled
        self.hardwareReady = hardwareReady
    }

    /// nil when the satellite is not a weather downlink an RTL-SDR setup can receive (X-band polar orbiters,
    /// geostationary relays, retired spacecraft), so the planner never offers a capture it cannot do.
    public static func make(for pass: SatellitePass, padding: TimeInterval = 120,
                            hardwareReady: Bool = false) -> SatelliteCaptureRecipe? {
        guard let downlink = SatelliteCaptureMode.downlink(for: pass.satellite.name) else { return nil }
        return SatelliteCaptureRecipe(
            pass: pass,
            mode: downlink.mode,
            downlinkFrequencyHz: downlink.frequencyHz,
            sampleRateHz: Self.sampleRate(for: downlink.mode),
            captureStart: pass.start.addingTimeInterval(-max(0, padding)),
            captureEnd: pass.end.addingTimeInterval(max(0, padding)),
            dopplerCorrectionEnabled: true,
            hardwareReady: hardwareReady)
    }

    public static func sampleRate(for mode: SatelliteCaptureMode) -> Double {
        switch mode {
        case .meteorLRPT: return 288_000
        case .noaaAPT: return 48_000
        case .metopAHRPT: return 2_400_000
        }
    }
}

public extension SatelliteCaptureMode {
    /// The downlink an RTL-SDR can take from this satellite. CelesTrak, Space-Track and older element sets spell the
    /// Meteor names differently ("METEOR-M2 4", "METEOR-M 2-4", "METEOR-M N2-4"), so match on letters and digits only.
    /// Frequencies are the operators' published values and have been moved before: verify against a current source
    /// before relying on one.
    static func downlink(for satelliteName: String) -> (mode: SatelliteCaptureMode, frequencyHz: Double)? {
        let name = satelliteName.uppercased().filter { $0.isLetter || $0.isNumber }
        if name.hasPrefix("METEORM") {
            // Only the two LRPT transmitters in service; M2-2 and earlier are not on air.
            switch name.last {
            case "3": return (.meteorLRPT, 137_900_000)
            case "4": return (.meteorLRPT, 137_100_000)
            default: return nil
            }
        }
        switch name {
        case "NOAA15": return (.noaaAPT, 137_620_000)
        case "NOAA18": return (.noaaAPT, 137_912_500)
        case "NOAA19": return (.noaaAPT, 137_100_000)
        default: break
        }
        if name.hasPrefix("METOP") { return (.metopAHRPT, 1_701_300_000) }
        return nil
    }
}

public struct SatelliteImageProduct: Identifiable, Equatable, Sendable {
    public var id: String
    public var satelliteName: String
    public var mode: SatelliteCaptureMode
    public var productName: String
    public var capturedAt: Date
    public var passStart: Date
    public var peakElevationDegrees: Double
    public var frequencyHz: Double
    public var width: Int
    public var height: Int
    public var qualityScore: Double
    public var decodedLineCount: Int
    public var isSimulated: Bool

    public init(id: String, satelliteName: String, mode: SatelliteCaptureMode, productName: String, capturedAt: Date,
                passStart: Date, peakElevationDegrees: Double, frequencyHz: Double, width: Int, height: Int,
                qualityScore: Double, decodedLineCount: Int, isSimulated: Bool) {
        self.id = id
        self.satelliteName = satelliteName
        self.mode = mode
        self.productName = productName
        self.capturedAt = capturedAt
        self.passStart = passStart
        self.peakElevationDegrees = peakElevationDegrees
        self.frequencyHz = frequencyHz
        self.width = width
        self.height = height
        self.qualityScore = qualityScore
        self.decodedLineCount = decodedLineCount
        self.isSimulated = isSimulated
    }

    public static func simulated(from recipe: SatelliteCaptureRecipe, capturedAt: Date = Date()) -> SatelliteImageProduct {
        let quality = min(0.98, max(0.12, recipe.pass.maxElevationDegrees / 90))
        let baseHeight = recipe.mode == .meteorLRPT ? 1568 : 900
        let height = max(180, Int(Double(baseHeight) * max(0.22, quality)))
        return SatelliteImageProduct(
            id: recipe.id + "-\(Int(capturedAt.timeIntervalSince1970))",
            satelliteName: recipe.pass.satellite.name,
            mode: recipe.mode,
            productName: recipe.mode.productName,
            capturedAt: capturedAt,
            passStart: recipe.pass.start,
            peakElevationDegrees: recipe.pass.maxElevationDegrees,
            frequencyHz: recipe.downlinkFrequencyHz,
            width: recipe.mode == .meteorLRPT ? 1568 : 1040,
            height: height,
            qualityScore: quality,
            decodedLineCount: Int(Double(height) * quality),
            isSimulated: !recipe.hardwareReady)
    }
}

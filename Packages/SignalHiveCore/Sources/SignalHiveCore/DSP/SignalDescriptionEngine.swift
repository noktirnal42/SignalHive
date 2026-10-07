import Foundation
import CoreLocation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Signal Description (always available)

public struct SignalDescription: Sendable {
    public var explanation: String
    public var confidence: String
    public var recommendation: String

    public init(explanation: String, confidence: String, recommendation: String) {
        self.explanation = explanation
        self.confidence = confidence
        self.recommendation = recommendation
    }
}

/// Plain RF context for explanations that do not depend on a Core ML classifier.
public struct SignalDescriptionContext: Equatable, Sendable {
    public var frequencyHz: Double
    public var mode: ChannelMode?
    public var bandwidthHz: Double?
    public var rssiDBFS: Double?
    public var licensee: String?
    public var callSign: String?
    public var serviceName: String?
    public var modeHints: [ModeHint]
    public var trunkedSystemName: String?
    public var talkgroupCode: Int?
    public var contextNote: String?

    public init(
        frequencyHz: Double,
        mode: ChannelMode? = nil,
        bandwidthHz: Double? = nil,
        rssiDBFS: Double? = nil,
        licensee: String? = nil,
        callSign: String? = nil,
        serviceName: String? = nil,
        modeHints: [ModeHint] = [],
        trunkedSystemName: String? = nil,
        talkgroupCode: Int? = nil,
        contextNote: String? = nil
    ) {
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.rssiDBFS = rssiDBFS
        self.licensee = licensee
        self.callSign = callSign
        self.serviceName = serviceName
        self.modeHints = modeHints
        self.trunkedSystemName = trunkedSystemName
        self.talkgroupCode = talkgroupCode
        self.contextNote = contextNote
    }
}

// MARK: - Signal Description Engine

/// Provides natural-language signal descriptions using Apple's on-device LLM.
/// Falls back to rule-based descriptions when Apple Intelligence is unavailable.
/// Foundation Models APIs (macOS 26+) are accessed via #available guards.
public actor SignalDescriptionEngine {
    private var cache: [String: SignalDescription] = [:]

    public init() {}

    public func describe(context: SignalDescriptionContext) async -> SignalDescription {
        let cacheKey = [
            "context",
            String(Int(context.frequencyHz.rounded())),
            context.mode?.rawValue ?? "",
            context.licensee ?? "",
            context.callSign ?? "",
            context.serviceName ?? "",
            context.trunkedSystemName ?? "",
            context.talkgroupCode.map(String.init) ?? "",
            context.contextNote ?? "",
            context.modeHints.map(\.rawValue).sorted().joined(separator: ",")
        ].joined(separator: "|")
        if let cached = cache[cacheKey] { return cached }

        let result = fallbackDescription(context: context)
        cache[cacheKey] = result
        return result
    }

    public func describe(
        classification: ClassificationResult,
        frequency: Double,
        bandwidth: Double,
        anomalyScore: Double,
        location: CLLocation? = nil
    ) async -> SignalDescription? {
        let cacheKey = "\(classification.topClass.rawValue)-\(Int(frequency / 1000))-\(Int(anomalyScore * 10))"
        if let cached = cache[cacheKey] { return cached }

        if #available(macOS 26.0, iOS 26.0, *) {
            if let result = await describeWithFoundationModels(
                classification: classification,
                frequency: frequency,
                bandwidth: bandwidth,
                anomalyScore: anomalyScore
            ) {
                cache[cacheKey] = result
                return result
            }
        }

        return fallbackDescription(classification: classification, frequency: frequency)
    }

    // MARK: - Foundation Models (macOS 26+)

    @available(macOS 26.0, iOS 26.0, *)
    private func describeWithFoundationModels(
        classification: ClassificationResult,
        frequency: Double,
        bandwidth: Double,
        anomalyScore: Double
    ) async -> SignalDescription? {
#if canImport(FoundationModels) && !SWIFT_PACKAGE
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession()
        let prompt = buildPrompt(classification: classification, frequency: frequency,
                                  bandwidth: bandwidth, anomalyScore: anomalyScore)
        do {
            let result = try await session.respond(to: prompt, generating: SignalDescriptionGenerable.self)
            return SignalDescription(
                explanation: result.content.explanation,
                confidence: result.content.confidence,
                recommendation: result.content.recommendation
            )
        } catch {
            return nil
        }
#else
        return nil
#endif
    }

    // MARK: - Fallback

    private func fallbackDescription(
        classification: ClassificationResult,
        frequency: Double
    ) -> SignalDescription {
        let freqMHz = frequency / 1_000_000
        return SignalDescription(
            explanation: "Detected \(classification.topClass.displayName) at \(String(format: "%.3f", freqMHz)) MHz (\(Int(classification.confidence * 100))% confidence).",
            confidence: classification.isHighConfidence ? "high" : "medium",
            recommendation: "Monitor signal for changes in modulation or power level."
        )
    }

    private func fallbackDescription(context: SignalDescriptionContext) -> SignalDescription {
        if let talkgroupCode = context.talkgroupCode {
            return fallbackTalkgroupDescription(context: context, talkgroupCode: talkgroupCode)
        }

        let profile = bandProfile(for: context.frequencyHz)
        let suggestedMode = context.mode ?? ChannelMode.suggested(
            frequencyHz: context.frequencyHz,
            hints: context.modeHints,
            bandwidthHz: context.bandwidthHz
        )
        let frequency = formatFrequency(context.frequencyHz)
        let licenseLine = licenseSummary(context)
        let modeLine = modeSummary(context: context, suggestedMode: suggestedMode)
        let rssiLine = context.rssiDBFS.map { String(format: " Current level is %.0f dBFS.", $0) } ?? ""

        return SignalDescription(
            explanation: "\(frequency) falls in \(profile.name). \(profile.likelyUse)\(licenseLine)\(rssiLine)",
            confidence: context.licensee == nil && context.callSign == nil ? "rules / medium" : "rules / high",
            recommendation: "\(modeLine) \(profile.nextAction)"
        )
    }

    private func fallbackTalkgroupDescription(
        context: SignalDescriptionContext,
        talkgroupCode: Int
    ) -> SignalDescription {
        let system = context.trunkedSystemName ?? context.licensee ?? "this trunked system"
        let service = context.serviceName ?? "unclassified service"
        let note = context.contextNote.map { " \($0)" } ?? ""
        return SignalDescription(
            explanation: "Talkgroup \(talkgroupCode) on \(system) is trunked-system metadata, not a fixed receive frequency. It appears to be \(service).\(note)",
            confidence: "rules / medium",
            recommendation: "Use Trunked to save the talkgroup to a scanner-capable codeplug, then find the system control channel or import verified trunking-site frequencies before expecting live following."
        )
    }

    private func bandProfile(for frequencyHz: Double) -> (name: String, likelyUse: String, nextAction: String) {
        switch frequencyHz {
        case 118_000_000...136_975_000:
            return (
                "the VHF aviation airband",
                "Expect AM voice from aircraft, towers, approach/departure, ATIS, AWOS, or related air operations.",
                "Use AM, keep bandwidth near 8-12.5 kHz, and try nearby published airport channels if the signal is intermittent."
            )
        case 137_000_000...138_000_000:
            return (
                "the VHF weather-satellite band",
                "This is where Meteor LRPT weather-satellite downlinks are received with RTL-SDR gear (NOAA's APT satellites have gone off the air).",
                "Use the Satellites screen to find a high pass, a wide enough IQ capture, and an LRPT decoder once recording is wired."
            )
        case 144_000_000...148_000_000:
            return (
                "the 2 meter amateur band",
                "Likely amateur FM repeaters, simplex, APRS packet, or weak-signal activity depending on the channel.",
                "Try NFM for voice repeaters, check repeater offsets before programming, and transmit only with the proper amateur license."
            )
        case 150_000_000...174_000_000:
            if (162_400_000...162_550_000).contains(frequencyHz) {
                return (
                    "the NOAA Weather Radio channels",
                    "Expect continuous NFM weather audio from a regional NOAA transmitter.",
                    "Use NFM around 12.5-25 kHz and save the strongest local channel to a weather scan list."
                )
            }
            return (
                "the VHF high land-mobile band",
                "Common users include public safety, business, industrial, school, utility, and local government systems.",
                "Use NFM first, compare the hit against installed FCC licenses, then save confirmed channels to a scan list."
            )
        case 225_000_000...400_000_000:
            return (
                "the UHF military aviation band",
                "Expect AM aircraft, military aviation, and related ground operations when activity is present.",
                "Use AM and a broader aviation scan plan; activity may be sporadic and location dependent."
            )
        case 400_000_000...406_000_000:
            return (
                "the radiosonde and meteorological telemetry range",
                "Weather balloons and telemetry payloads often appear in this neighborhood.",
                "Use the radiosonde decoder path when available and log GPS-derived positions with the receiver location."
            )
        case 406_000_000...420_000_000:
            return (
                "the federal UHF land-mobile range",
                "Expect federal government, telemetry, and specialized land-mobile assignments.",
                "Use NFM unless the emission hints say otherwise, then correlate against any installed federal records."
            )
        case 420_000_000...450_000_000:
            return (
                "the 70 centimeter amateur band",
                "Likely amateur repeaters, simplex, packet, or digital voice depending on the local channel plan.",
                "Try NFM or the digital mode shown by FCC/emission hints, and verify offsets before programming."
            )
        case 450_000_000...470_000_000:
            return (
                "the UHF business and public-safety land-mobile band",
                "Common users include business, public safety, schools, utilities, and local government.",
                "Use NFM first, check for P25/DMR clues, and save confirmed channels with license context."
            )
        case 470_000_000...512_000_000:
            return (
                "the UHF T-band",
                "In metro areas this can carry public safety, business, and legacy land-mobile channels.",
                "Use NFM/P25 based on emissions and scan adjacent 12.5 kHz channels for paired activity."
            )
        case 764_000_000...776_000_000, 794_000_000...806_000_000, 806_000_000...869_000_000:
            return (
                "the 700/800 MHz land-mobile and trunking range",
                "Often used by public-safety and regional trunked systems rather than isolated conventional channels.",
                "Look for a control channel, then use Trunked/OpenMHz context or a future control-channel decoder."
            )
        case 902_000_000...928_000_000:
            return (
                "the 902-928 MHz ISM band",
                "Expect unlicensed telemetry, sensors, IoT links, paging-like bursts, or amateur activity.",
                "Use burst capture and the ISM decoder path once it is reachable from the app."
            )
        case 977_500_000...978_500_000:
            return (
                "the 978 MHz UAT aviation channel",
                "This is UAT ADS-B plus FIS-B weather and traffic rebroadcasts in the United States.",
                "Use the Air Map 978 MHz receiver with the antenna position set before expecting weather products."
            )
        case 1_089_500_000...1_090_500_000:
            return (
                "the 1090 MHz Mode S / ADS-B aviation channel",
                "Expect aircraft transponder replies and ADS-B extended squitters.",
                "Use the Air Map 1090 MHz receiver and wait for paired position messages before judging range."
            )
        default:
            return (
                "a general RF monitoring range",
                "The likely source depends on local allocations, installed FCC packs, and the signal's modulation.",
                "Start with the suggested demodulator, compare against nearby FCC records, and record a short IQ sample if it is unknown."
            )
        }
    }

    private func modeSummary(context: SignalDescriptionContext, suggestedMode: ChannelMode) -> String {
        let width: String
        if let bandwidthHz = context.bandwidthHz, bandwidthHz > 0 {
            width = String(format: " with roughly %.1f kHz bandwidth", bandwidthHz / 1_000)
        } else {
            width = ""
        }
        let hints = context.modeHints.filter { $0 != .unknown }.map(\.displayName)
        let hintLine = hints.isEmpty ? "" : " Hints: \(hints.joined(separator: ", "))."
        return "Start with \(suggestedMode.rawValue)\(width).\(hintLine)"
    }

    private func licenseSummary(_ context: SignalDescriptionContext) -> String {
        let parts = [
            context.callSign.map { "call sign \($0)" },
            context.licensee.map { "licensee \($0)" },
            context.serviceName.map { "service \($0)" }
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "" }
        return " Installed FCC context shows \(parts.joined(separator: ", "))."
    }

    private func formatFrequency(_ frequencyHz: Double) -> String {
        if frequencyHz >= 1_000_000_000 {
            return String(format: "%.5f GHz", frequencyHz / 1_000_000_000)
        }
        if frequencyHz >= 1_000_000 {
            return String(format: "%.5f MHz", frequencyHz / 1_000_000)
        }
        if frequencyHz >= 1_000 {
            return String(format: "%.3f kHz", frequencyHz / 1_000)
        }
        return String(format: "%.0f Hz", frequencyHz)
    }

    private func buildPrompt(
        classification: ClassificationResult,
        frequency: Double,
        bandwidth: Double,
        anomalyScore: Double
    ) -> String {
        let freqMHz = frequency / 1_000_000
        let bwKHz = bandwidth / 1_000
        let anomalyNote = anomalyScore > 3 ? " Anomaly score: \(String(format: "%.1f", anomalyScore))σ." : ""
        return """
        You are an RF signals analyst. Describe this signal in 1-2 sentences.
        - Modulation: \(classification.topClass.displayName) (\(Int(classification.confidence * 100))%)
        - Frequency: \(String(format: "%.3f", freqMHz)) MHz
        - Bandwidth: \(String(format: "%.1f", bwKHz)) kHz
        \(anomalyNote)
        Describe the likely source and one recommended action.
        """
    }
}

// MARK: - Generable struct for Foundation Models (macOS 26+ only)

#if canImport(FoundationModels) && !SWIFT_PACKAGE
@available(macOS 26.0, iOS 26.0, *)
@Generable
private struct SignalDescriptionGenerable: Sendable {
    @Guide(description: "1-2 sentence description of the likely signal source and characteristics")
    var explanation: String

    @Guide(description: "Confidence level: 'high', 'medium', or 'low'")
    var confidence: String

    @Guide(description: "One recommended action for the RF operator, 1 sentence")
    var recommendation: String
}
#endif

// MARK: - Pattern of Life Engine (Port from MarineTrackAI)

/// Detects anomalous vessel behavior patterns in AIS data.
public actor PatternOfLifeEngine {
    // MARK: - Rule-based detection thresholds

    private let darkShipSilenceHours: Double = 6.0
    private let speedJumpKnots: Float = 100.0

    private var vesselHistory: [Int: [AISPositionRecord]] = [:]
    private var lastSeen: [Int: Date] = [:]
    private var alerts: [PatternOfLifeAlert] = []

    public init() {}

    public func update(message: AISMessage) async -> PatternOfLifeAlert? {
        let mmsi = message.mmsi
        lastSeen[mmsi] = message.timestamp

        if let pos = message.position {
            let record = AISPositionRecord(
                timestamp: message.timestamp,
                coordinate: pos,
                speedOverGround: 0,
                courseOverGround: 0,
                heading: 0,
                navigationStatus: 0
            )
            var history = vesselHistory[mmsi] ?? []
            history.append(record)
            if history.count > 500 { history.removeFirst() }
            vesselHistory[mmsi] = history

            if let spoofAlert = checkSpoofing(mmsi: mmsi, history: history) {
                alerts.append(spoofAlert)
                return spoofAlert
            }
        }

        if let darkAlert = checkDarkShip(mmsi: mmsi) {
            alerts.append(darkAlert)
            return darkAlert
        }

        return nil
    }

    private func checkSpoofing(mmsi: Int, history: [AISPositionRecord]) -> PatternOfLifeAlert? {
        guard history.count >= 2 else { return nil }
        let last = history[history.count - 1]
        let prev = history[history.count - 2]
        let timeDelta = last.timestamp.timeIntervalSince(prev.timestamp)
        guard timeDelta > 0 else { return nil }

        let dist = haversineNm(from: prev.coordinate, to: last.coordinate)
        let impliedSpeed = Float(dist / (timeDelta / 3600))

        if impliedSpeed > speedJumpKnots {
            return PatternOfLifeAlert(
                type: .spoofing,
                mmsi: mmsi,
                timestamp: .now,
                description: "Position jump of \(String(format: "%.0f", dist)) nm in \(Int(timeDelta/60)) minutes implies \(Int(impliedSpeed)) knots — likely AIS spoofing"
            )
        }
        return nil
    }

    private func checkDarkShip(mmsi: Int) -> PatternOfLifeAlert? {
        guard let last = lastSeen[mmsi] else { return nil }
        let silenceHours = Date().timeIntervalSince(last) / 3600
        guard silenceHours > darkShipSilenceHours else { return nil }
        guard vesselHistory[mmsi]?.isEmpty == false else { return nil }

        return PatternOfLifeAlert(
            type: .darkShip,
            mmsi: mmsi,
            timestamp: .now,
            description: "No AIS signal for \(String(format: "%.1f", silenceHours)) hours — vessel may have disabled transponder"
        )
    }

    public func recentAlerts(limit: Int = 100) -> [PatternOfLifeAlert] {
        Array(alerts.suffix(limit))
    }

    private func haversineNm(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let R = 3440.065
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let a = sin(dLat/2)*sin(dLat/2) + cos(from.latitude * .pi/180)*cos(to.latitude * .pi/180)*sin(dLon/2)*sin(dLon/2)
        return R * 2 * atan2(sqrt(a), sqrt(1-a))
    }
}

public struct PatternOfLifeAlert: Identifiable, Sendable {
    public let id = UUID()
    public var type: AlertType
    public var mmsi: Int
    public var timestamp: Date
    public var description: String

    public enum AlertType: String, Sendable {
        case darkShip   = "Dark Ship"
        case spoofing   = "Position Spoofing"
        case rendezvous = "Rendezvous"
    }
}

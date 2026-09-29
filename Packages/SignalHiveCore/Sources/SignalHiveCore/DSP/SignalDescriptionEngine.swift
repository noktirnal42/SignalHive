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

// MARK: - Signal Description Engine

/// Provides natural-language signal descriptions using Apple's on-device LLM.
/// Falls back to rule-based descriptions when Apple Intelligence is unavailable.
/// Foundation Models APIs (macOS 26+) are accessed via #available guards.
public actor SignalDescriptionEngine {
    private var cache: [String: SignalDescription] = [:]

    public init() {}

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

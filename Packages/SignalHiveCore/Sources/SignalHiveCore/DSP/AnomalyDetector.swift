import Foundation
import Accelerate

// MARK: - Anomaly Detection Result

public struct AnomalyEvent: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let frequency: Double
    public let mahalanobisDistance: Double
    public let classificationAtEvent: ClassificationResult
    public let baselineSnapshot: [Float]  // mean confidence vector at time of event

    public var severity: Severity {
        switch mahalanobisDistance {
        case ..<3:  return .low
        case 3..<5: return .medium
        default:    return .high
        }
    }

    public enum Severity: String, Sendable {
        case low = "Low", medium = "Medium", high = "High"
    }
}

public struct AnomalyEventExportRecord: Codable, Sendable, Equatable {
    public struct Candidate: Codable, Sendable, Equatable {
        public let className: String
        public let confidence: Float

        public init(className: String, confidence: Float) {
            self.className = className
            self.confidence = confidence
        }
    }

    public let timestamp: Date
    public let frequencyHz: Double
    public let severity: String
    public let mahalanobisDistance: Double
    public let topClass: String
    public let confidence: Float
    public let inferenceMs: Double
    public let baselineSnapshot: [Float]
    public let topCandidates: [Candidate]

    public init(event: AnomalyEvent) {
        self.timestamp = event.timestamp
        self.frequencyHz = event.frequency
        self.severity = event.severity.rawValue
        self.mahalanobisDistance = event.mahalanobisDistance
        self.topClass = event.classificationAtEvent.topClass.displayName
        self.confidence = event.classificationAtEvent.confidence
        self.inferenceMs = event.classificationAtEvent.inferenceMs
        self.baselineSnapshot = event.baselineSnapshot
        self.topCandidates = event.classificationAtEvent.topFive.map {
            Candidate(className: $0.0.displayName, confidence: $0.1)
        }
    }
}

public enum AnomalyEventExportFormatter {
    public static func records(from events: [AnomalyEvent]) -> [AnomalyEventExportRecord] {
        events.map(AnomalyEventExportRecord.init)
    }

    public static func csv(events: [AnomalyEvent]) -> String {
        let formatter = timestampFormatter
        let header = "timestamp,frequency_hz,severity,mahalanobis_distance,top_class,confidence,inference_ms"
        let rows = events.map { event in
            [
                formatter.string(from: event.timestamp),
                String(event.frequency),
                event.severity.rawValue,
                String(format: "%.6f", event.mahalanobisDistance),
                csvField(event.classificationAtEvent.topClass.displayName),
                String(format: "%.6f", event.classificationAtEvent.confidence),
                String(format: "%.6f", event.classificationAtEvent.inferenceMs),
            ]
            .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    public static func jsonData(events: [AnomalyEvent], prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(records(from: events))
    }

    private static var timestampFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

// MARK: - AnomalyDetector

/// Detects anomalous signals using Mahalanobis distance on the 24-dimensional
/// softmax confidence vector from AutoClassifier.
///
/// Port from RF Sentinel (AFWERX). Upgraded from 11-class to 24-class.
public actor AnomalyDetector {
    // MARK: - Configuration

    public struct Config: Sendable {
        public var windowMinutes: Double = 10     // rolling baseline window
        public var updateIntervalSec: Double = 30
        public var sigmaThreshold: Double = 3.0   // alert threshold (configurable 2–5σ)
        public var minSamplesForBaseline: Int = 60

        public init() {}
    }

    private let config: Config
    private let dimensions = 24  // RadioML 2018.01a classes

    // Rolling window of confidence vectors
    private var window: [[Float]] = []
    private let maxWindowSize: Int

    // Baseline statistics (updated every 30s)
    private var baselineMean: [Float]
    private var covarianceMatrix: [[Double]]
    private var inverseCovarianceMatrix: [[Double]]
    private var isBaselineValid = false

    // Alert history
    private var events: [AnomalyEvent] = []
    public private(set) var alertCount: Int = 0

    // MARK: - Init

    public init(config: Config = .init()) {
        self.config = config
        let sampleRate = 60.0 / 30.0  // ~2 classifications/min
        self.maxWindowSize = Int(config.windowMinutes * 60 * sampleRate)
        self.baselineMean = [Float](repeating: 0, count: dimensions)
        self.covarianceMatrix = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 24)
        self.inverseCovarianceMatrix = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 24)
    }

    // MARK: - Processing

    public func process(
        classification: ClassificationResult,
        frequency: Double
    ) -> AnomalyEvent? {
        var vector = classification.topFive.reduce(into: [Float](repeating: 0, count: dimensions)) { acc, pair in
            if let idx = RadioMLClass.allCases.firstIndex(of: pair.0) {
                acc[idx] = pair.1
            }
        }
        // Fill remaining probability to top class
        if let topIdx = RadioMLClass.allCases.firstIndex(of: classification.topClass) {
            vector[topIdx] = max(vector[topIdx], classification.confidence)
        }

        // Add to rolling window
        window.append(vector)
        if window.count > maxWindowSize { window.removeFirst() }

        // Update baseline periodically
        if window.count % 30 == 0 || !isBaselineValid {
            updateBaseline()
        }

        guard isBaselineValid else { return nil }

        // Compute Mahalanobis distance
        let distance = mahalanobisDistance(vector: vector)

        guard distance > config.sigmaThreshold else { return nil }

        // Anomaly detected
        alertCount += 1
        let event = AnomalyEvent(
            timestamp: classification.timestamp,
            frequency: frequency,
            mahalanobisDistance: distance,
            classificationAtEvent: classification,
            baselineSnapshot: baselineMean
        )
        events.append(event)
        if events.count > 1000 { events.removeFirst() }
        return event
    }

    public func recentEvents(limit: Int = 50) -> [AnomalyEvent] {
        Array(events.suffix(limit))
    }

    public func resetBaseline() {
        window.removeAll()
        isBaselineValid = false
        alertCount = 0
    }

    // MARK: - Statistics

    private func updateBaseline() {
        guard window.count >= config.minSamplesForBaseline else { return }

        // Compute mean vector
        var mean = [Float](repeating: 0, count: dimensions)
        for vec in window {
            for d in 0..<dimensions {
                mean[d] += vec[d]
            }
        }
        let n = Float(window.count)
        mean = mean.map { $0 / n }
        baselineMean = mean

        // Compute covariance matrix
        var cov = [[Double]](repeating: [Double](repeating: 0, count: dimensions), count: dimensions)
        for vec in window {
            let diff = vec.enumerated().map { Double($0.element) - Double(mean[$0.offset]) }
            for i in 0..<dimensions {
                for j in 0..<dimensions {
                    cov[i][j] += diff[i] * diff[j]
                }
            }
        }
        let nD = Double(window.count - 1)
        for i in 0..<dimensions {
            for j in 0..<dimensions {
                cov[i][j] /= nD
            }
        }
        covarianceMatrix = cov

        // Pseudo-inverse via regularization (add λI to avoid singular matrix)
        let lambda = 1e-6
        for i in 0..<dimensions {
            covarianceMatrix[i][i] += lambda
        }
        inverseCovarianceMatrix = invertMatrix(covarianceMatrix)
        isBaselineValid = true
    }

    private func mahalanobisDistance(vector: [Float]) -> Double {
        let diff = vector.enumerated().map { Double($0.element) - Double(baselineMean[$0.offset]) }

        // d² = (x-μ)ᵀ Σ⁻¹ (x-μ)
        var temp = [Double](repeating: 0, count: dimensions)
        for i in 0..<dimensions {
            for j in 0..<dimensions {
                temp[i] += inverseCovarianceMatrix[i][j] * diff[j]
            }
        }
        var dSquared = 0.0
        for i in 0..<dimensions {
            dSquared += temp[i] * diff[i]
        }
        return sqrt(max(0, dSquared))
    }

    // MARK: - Matrix inversion (Gauss-Jordan for small matrices)

    private func invertMatrix(_ matrix: [[Double]]) -> [[Double]] {
        let n = matrix.count
        var augmented = matrix.enumerated().map { row, cols -> [Double] in
            let r = cols
            var identity = [Double](repeating: 0, count: n)
            identity[row] = 1
            return r + identity
        }

        for col in 0..<n {
            // Find pivot
            var pivotRow = col
            for row in col+1..<n {
                if abs(augmented[row][col]) > abs(augmented[pivotRow][col]) {
                    pivotRow = row
                }
            }
            augmented.swapAt(col, pivotRow)

            let pivot = augmented[col][col]
            guard abs(pivot) > 1e-12 else { continue }

            // Normalize pivot row
            augmented[col] = augmented[col].map { $0 / pivot }

            // Eliminate column
            for row in 0..<n where row != col {
                let factor = augmented[row][col]
                augmented[row] = augmented[row].enumerated().map {
                    $0.element - factor * augmented[col][$0.offset]
                }
            }
        }

        return augmented.map { Array($0.dropFirst(n)) }
    }
}

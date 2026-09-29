import Foundation
import CoreML
import Accelerate

// MARK: - Classification Result

public struct ClassificationResult: Sendable {
    public let topClass: RadioMLClass
    public let confidence: Float
    public let topFive: [(RadioMLClass, Float)]
    public let timestamp: Date
    public let inferenceMs: Double

    public var isHighConfidence: Bool { confidence > 0.75 }
}

// MARK: - RadioML 2018.01a Classes (24 classes)

public enum RadioMLClass: String, CaseIterable, Sendable, Codable {
    case OOK      = "OOK"
    case AM_DSB_WC = "AM-DSB-WC"
    case AM_DSB_SC = "AM-DSB-SC"
    case AM_SSB_WC = "AM-SSB-WC"
    case AM_SSB_SC = "AM-SSB-SC"
    case FM       = "FM"
    case GMSK     = "GMSK"
    case OQPSK    = "OQPSK"
    case BPSK     = "BPSK"
    case QPSK     = "QPSK"
    case PSK8     = "8PSK"
    case PSK16    = "16PSK"
    case PSK32    = "32PSK"
    case ASK4     = "4ASK"
    case ASK8     = "8ASK"
    case APSK16   = "16APSK"
    case APSK32   = "32APSK"
    case APSK64   = "64APSK"
    case APSK128  = "128APSK"
    case QAM16    = "16QAM"
    case QAM32    = "32QAM"
    case QAM64    = "64QAM"
    case QAM128   = "128QAM"
    case QAM256   = "256QAM"

    public var displayName: String { rawValue }

    public var category: SignalCategory {
        switch self {
        case .OOK, .AM_DSB_WC, .AM_DSB_SC, .AM_SSB_WC, .AM_SSB_SC:
            return .analog
        case .FM, .GMSK:
            return .analog
        case .OQPSK, .BPSK, .QPSK, .PSK8, .PSK16, .PSK32:
            return .phaseShiftKeying
        case .ASK4, .ASK8:
            return .amplitudeShiftKeying
        case .APSK16, .APSK32, .APSK64, .APSK128:
            return .apsk
        case .QAM16, .QAM32, .QAM64, .QAM128, .QAM256:
            return .qam
        }
    }

    public enum SignalCategory: String, Sendable {
        case analog = "Analog"
        case phaseShiftKeying = "PSK"
        case amplitudeShiftKeying = "ASK"
        case apsk = "APSK"
        case qam = "QAM"
    }
}

// MARK: - Bundled Model Contract

public struct AutoClassifierModelContract: Codable, Sendable, Equatable {
    public var modelPackageName: String
    public var inputFeatureName: String
    public var outputFeatureName: String
    public var benchmarkArtifactName: String
    public var evaluationArtifactName: String
    public var minimumClassCount: Int
    public var modelVersion: String
    public var dataset: String

    public init(
        modelPackageName: String = "AutoClassify_v2.mlpackage",
        inputFeatureName: String = "iq_input",
        outputFeatureName: String = "class_probs",
        benchmarkArtifactName: String = "AutoClassify_v2_benchmark.json",
        evaluationArtifactName: String = "accuracy_by_snr.json",
        minimumClassCount: Int = 24,
        modelVersion: String = "2.0",
        dataset: String = "RadioML 2018.01a"
    ) {
        self.modelPackageName = modelPackageName
        self.inputFeatureName = inputFeatureName
        self.outputFeatureName = outputFeatureName
        self.benchmarkArtifactName = benchmarkArtifactName
        self.evaluationArtifactName = evaluationArtifactName
        self.minimumClassCount = minimumClassCount
        self.modelVersion = modelVersion
        self.dataset = dataset
    }

    public static let current = AutoClassifierModelContract()
}

public struct AutoClassifierBundledAssetStatus: Sendable, Equatable {
    public let contract: AutoClassifierModelContract
    public let contractSource: String
    public let searchRoots: [URL]
    public let manifestURL: URL?
    public let modelURL: URL?
    public let benchmarkURL: URL?
    public let evaluationURL: URL?

    public var hasModelPackage: Bool { modelURL != nil }

    public var missingSupportingArtifacts: [String] {
        var missing: [String] = []
        if benchmarkURL == nil {
            missing.append(contract.benchmarkArtifactName)
        }
        if evaluationURL == nil {
            missing.append(contract.evaluationArtifactName)
        }
        return missing
    }
}

public struct AutoClassifierBenchmarkEvidence: Codable, Sendable, Equatable {
    public let meanMs: Double
    public let medianMs: Double
    public let p95Ms: Double
    public let p99Ms: Double
    public let minMs: Double
    public let maxMs: Double

    enum CodingKeys: String, CodingKey {
        case meanMs = "mean_ms"
        case medianMs = "median_ms"
        case p95Ms = "p95_ms"
        case p99Ms = "p99_ms"
        case minMs = "min_ms"
        case maxMs = "max_ms"
    }

    public var allValues: [Double] {
        [meanMs, medianMs, p95Ms, p99Ms, minMs, maxMs]
    }

    public var passesBasicSanity: Bool {
        allValues.allSatisfy { $0 >= 0 } &&
        minMs <= medianMs &&
        medianMs <= p95Ms &&
        p95Ms <= p99Ms &&
        p99Ms <= maxMs
    }
}

public struct AutoClassifierEvaluationRow: Codable, Sendable, Equatable {
    public let snr: Double
    public let perClassAccuracy: [Double]
    public let overallAccuracy: Double

    enum CodingKeys: String, CodingKey {
        case snr
        case perClassAccuracy = "per_class_accuracy"
        case overallAccuracy = "overall_accuracy"
    }
}

public struct AutoClassifierEvaluationEvidence: Codable, Sendable, Equatable {
    public let snrValues: [Double]
    public let classes: [String]
    public let accuracyMatrix: [AutoClassifierEvaluationRow]

    enum CodingKeys: String, CodingKey {
        case snrValues = "snr_values"
        case classes
        case accuracyMatrix = "accuracy_matrix"
    }

    public func highSNRAverageAccuracy(minimumSNR: Double = 10) -> Double? {
        let rows = accuracyMatrix.filter { $0.snr >= minimumSNR }
        guard !rows.isEmpty else { return nil }
        let total = rows.reduce(0.0) { $0 + $1.overallAccuracy }
        return total / Double(rows.count)
    }

    public func passesBasicSanity(minimumClassCount: Int) -> Bool {
        guard classes.count >= minimumClassCount, !accuracyMatrix.isEmpty else {
            return false
        }

        let classSet = Set(classes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard classSet.count == classes.count else { return false }

        for row in accuracyMatrix {
            guard row.perClassAccuracy.count >= minimumClassCount else { return false }
            guard (0...1).contains(row.overallAccuracy) else { return false }
            guard row.perClassAccuracy.allSatisfy({ (0...1).contains($0) }) else { return false }
        }

        return true
    }
}

public struct AutoClassifierBundleValidationResult: Sendable, Equatable {
    public let assetStatus: AutoClassifierBundledAssetStatus
    public let benchmark: AutoClassifierBenchmarkEvidence?
    public let evaluation: AutoClassifierEvaluationEvidence?
    public let issues: [String]

    public var passed: Bool { issues.isEmpty }
}

public enum AutoClassifierBundleValidator {
    public static func validate(
        searchRoots explicitSearchRoots: [URL]? = nil
    ) -> AutoClassifierBundleValidationResult {
        validate(assetStatus: AutoClassifierAssetLocator.resolve(searchRoots: explicitSearchRoots))
    }

    public static func validate(
        assetStatus: AutoClassifierBundledAssetStatus
    ) -> AutoClassifierBundleValidationResult {
        var issues: [String] = []

        if assetStatus.modelURL == nil {
            issues.append("missing model package \(assetStatus.contract.modelPackageName)")
        }

        let benchmark = decodeBenchmark(from: assetStatus.benchmarkURL, issues: &issues, assetStatus: assetStatus)
        let evaluation = decodeEvaluation(from: assetStatus.evaluationURL, issues: &issues, assetStatus: assetStatus)

        return AutoClassifierBundleValidationResult(
            assetStatus: assetStatus,
            benchmark: benchmark,
            evaluation: evaluation,
            issues: issues
        )
    }

    private static func decodeBenchmark(
        from url: URL?,
        issues: inout [String],
        assetStatus: AutoClassifierBundledAssetStatus
    ) -> AutoClassifierBenchmarkEvidence? {
        guard let url else {
            issues.append("missing benchmark artifact \(assetStatus.contract.benchmarkArtifactName)")
            return nil
        }

        do {
            let benchmark = try JSONDecoder().decode(
                AutoClassifierBenchmarkEvidence.self,
                from: Data(contentsOf: url)
            )
            if !benchmark.passesBasicSanity {
                issues.append("invalid benchmark artifact \(url.lastPathComponent)")
            }
            return benchmark
        } catch {
            issues.append("unreadable benchmark artifact \(url.lastPathComponent)")
            return nil
        }
    }

    private static func decodeEvaluation(
        from url: URL?,
        issues: inout [String],
        assetStatus: AutoClassifierBundledAssetStatus
    ) -> AutoClassifierEvaluationEvidence? {
        guard let url else {
            issues.append("missing evaluation artifact \(assetStatus.contract.evaluationArtifactName)")
            return nil
        }

        do {
            let evaluation = try JSONDecoder().decode(
                AutoClassifierEvaluationEvidence.self,
                from: Data(contentsOf: url)
            )
            if !evaluation.passesBasicSanity(minimumClassCount: assetStatus.contract.minimumClassCount) {
                issues.append("invalid evaluation artifact \(url.lastPathComponent)")
            }
            return evaluation
        } catch {
            issues.append("unreadable evaluation artifact \(url.lastPathComponent)")
            return nil
        }
    }
}

public enum AutoClassifierAssetLocator {
    private final class BundleToken {}

    public static func resolve(searchRoots explicitSearchRoots: [URL]? = nil) -> AutoClassifierBundledAssetStatus {
        let searchRoots = explicitSearchRoots ?? defaultSearchRoots()
        let manifestName = "AutoClassify_v2.manifest.json"
        let manifestURL = firstMatch(named: manifestName, under: searchRoots)
        let contract = loadContract(from: manifestURL) ?? .current
        let contractSource = manifestURL == nil ? "default" : manifestName

        return AutoClassifierBundledAssetStatus(
            contract: contract,
            contractSource: contractSource,
            searchRoots: searchRoots,
            manifestURL: manifestURL,
            modelURL: firstMatch(named: contract.modelPackageName, under: searchRoots),
            benchmarkURL: firstMatch(named: contract.benchmarkArtifactName, under: searchRoots),
            evaluationURL: firstMatch(named: contract.evaluationArtifactName, under: searchRoots)
        )
    }

    private static func defaultSearchRoots() -> [URL] {
        var roots: [URL] = []

        #if SWIFT_PACKAGE
        if let resourceURL = Bundle.module.resourceURL {
            roots.append(resourceURL)
        }
        #endif

        let frameworkBundle = Bundle(for: BundleToken.self)
        if let resourceURL = frameworkBundle.resourceURL {
            roots.append(resourceURL)
        }
        if let mainResourceURL = Bundle.main.resourceURL {
            roots.append(mainResourceURL)
        }
        if let privateFrameworksURL = Bundle.main.privateFrameworksURL {
            roots.append(privateFrameworksURL)
        }
        if let sharedFrameworksURL = Bundle.main.sharedFrameworksURL {
            roots.append(sharedFrameworksURL)
        }

        var deduped: [URL] = []
        var seen = Set<String>()
        for root in roots {
            let standardized = root.standardizedFileURL.path
            if seen.insert(standardized).inserted {
                deduped.append(root)
            }
        }
        return deduped
    }

    private static func firstMatch(named name: String, under roots: [URL]) -> URL? {
        for root in roots {
            if root.lastPathComponent == name {
                return root
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == name {
                    return fileURL
                }
            }
        }
        return nil
    }

    private static func loadContract(from manifestURL: URL?) -> AutoClassifierModelContract? {
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(AutoClassifierModelContract.self, from: data)
    }
}

// MARK: - AutoClassifier

/// Wraps the AutoClassify_v2 CoreML model for real-time signal classification.
/// Runs on Apple Neural Engine via CoreML with W8A8 INT8 quantization.
public final class AutoClassifier: @unchecked Sendable {
    // MLModel is not Sendable but AutoClassifier is internally synchronized
    // through async/await usage — only called from async contexts.
    private nonisolated(unsafe) let model: MLModel
    private let inputName: String
    private let outputName: String
    private let classes = RadioMLClass.allCases

    // Inference statistics
    private let inferenceTimes = OSAllocatedUnfairLock<[Double]>(initialState: [])

    public convenience init() throws {
        try self.init(assetStatus: AutoClassifierAssetLocator.resolve())
    }

    public init(assetStatus: AutoClassifierBundledAssetStatus) throws {
        guard let modelURL = assetStatus.modelURL else {
            throw ClassifierError.modelNotFound
        }
        guard assetStatus.contract.minimumClassCount <= RadioMLClass.allCases.count else {
            throw ClassifierError.invalidContract
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all  // Prefer ANE, fall back to GPU then CPU
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.inputName = assetStatus.contract.inputFeatureName
        self.outputName = assetStatus.contract.outputFeatureName
    }

    // MARK: - Inference

    public func classify(iq: [ComplexFloat]) async -> ClassificationResult {
        let start = Date()

        // Prepare input: (1, 2, 1024) float32 tensor
        // Channel 0: I samples, Channel 1: Q samples
        let n = min(iq.count, 1024)
        var iChannel = [Float](repeating: 0, count: 1024)
        var qChannel = [Float](repeating: 0, count: 1024)
        for i in 0..<n {
            iChannel[i] = iq[i].i
            qChannel[i] = iq[i].q
        }

        // Normalize to unit variance
        normalize(&iChannel)
        normalize(&qChannel)

        // Create MLMultiArray (1, 2, 1024)
        guard let input = try? MLMultiArray(shape: [1, 2, 1024], dataType: .float32) else {
            return ClassificationResult(
                topClass: .FM, confidence: 0, topFive: [],
                timestamp: .now, inferenceMs: 0
            )
        }
        for i in 0..<1024 {
            input[[0, 0, i as NSNumber] as [NSNumber]] = NSNumber(value: iChannel[i])
            input[[0, 1, i as NSNumber] as [NSNumber]] = NSNumber(value: qChannel[i])
        }

        // Run inference
        guard let output = try? await model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(multiArray: input)]
        )),
        let probs = output.featureValue(for: outputName)?.multiArrayValue else {
            return ClassificationResult(
                topClass: .FM, confidence: 0, topFive: [],
                timestamp: .now, inferenceMs: 0
            )
        }

        // Extract probabilities
        let outputCount = min(classes.count, probs.count)
        guard outputCount > 0 else {
            return ClassificationResult(
                topClass: .FM, confidence: 0, topFive: [],
                timestamp: .now, inferenceMs: 0
            )
        }

        let probArray = (0..<outputCount).map { Float(truncating: probs[$0]) }
        let inferenceTime = Date().timeIntervalSince(start) * 1000
        inferenceTimes.withLock { $0.append(inferenceTime) }

        return buildResult(probabilities: probArray, inferenceMs: inferenceTime)
    }

    private func buildResult(probabilities: [Float], inferenceMs: Double) -> ClassificationResult {
        guard !probabilities.isEmpty else {
            return ClassificationResult(
                topClass: .FM,
                confidence: 0,
                topFive: [],
                timestamp: .now,
                inferenceMs: inferenceMs
            )
        }

        let indexed = probabilities.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { $0.1 > $1.1 }
        let topFive = sorted.prefix(5).map { (classes[$0.0], $0.1) }
        let topClass = classes[sorted[0].0]

        return ClassificationResult(
            topClass: topClass,
            confidence: sorted[0].1,
            topFive: Array(topFive),
            timestamp: .now,
            inferenceMs: inferenceMs
        )
    }

    private func normalize(_ samples: inout [Float]) {
        var mean: Float = 0
        var stddev: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var sq: Float = 0
        vDSP_measqv(samples, 1, &sq, vDSP_Length(samples.count))
        stddev = sqrtf(max(sq - mean * mean, 1e-10))
        samples = samples.map { ($0 - mean) / stddev }
    }

    public enum ClassifierError: Error {
        case modelNotFound
        case invalidContract
    }
}

// MARK: - Mock classifier for development without .mlpackage

/// Returns plausible classification based on signal bandwidth — used during development
/// before the CoreML model is trained and exported.
public final class MockAutoClassifier: Sendable {
    public init() {}

    public func classify(iq: [ComplexFloat]) async -> ClassificationResult {
        // Simple heuristic: estimate by power distribution
        let power = iq.map(\.powerLinear)
        let variance = power.reduce(0, +) / Float(power.count)
        let modClass: RadioMLClass = variance > 0.1 ? .FM : .BPSK

        return ClassificationResult(
            topClass: modClass,
            confidence: 0.72,
            topFive: [
                (modClass, 0.72),
                (.QPSK, 0.15),
                (.GMSK, 0.08),
                (.AM_DSB_WC, 0.03),
                (.OOK, 0.02)
            ],
            timestamp: .now,
            inferenceMs: 1.2
        )
    }
}

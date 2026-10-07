import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum AIProviderKind: String, CaseIterable, Sendable, Codable {
    case coreML
    case foundationOnDevice
    case foundationPrivateCloud
    case mlxLocal
    case rulesEngine

    public var displayName: String {
        switch self {
        case .coreML: return "Core ML"
        case .foundationOnDevice: return "Apple Foundation Model"
        case .foundationPrivateCloud: return "Private Cloud Compute"
        case .mlxLocal: return "MLX Local"
        case .rulesEngine: return "SignalHive Rules"
        }
    }
}

public enum AIFeatureStatus: String, CaseIterable, Sendable, Codable {
    case available
    case readyWhenAvailable
    case requiresEntitlement
    case needsModel
    case planned
    case notRecommended

    public var displayName: String {
        switch self {
        case .available: return "Available"
        case .readyWhenAvailable: return "Runtime gated"
        case .requiresEntitlement: return "Entitlement gated"
        case .needsModel: return "Needs model"
        case .planned: return "Planned"
        case .notRecommended: return "Not recommended"
        }
    }
}

public struct AIFeature: Identifiable, Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var category: String
    public var provider: AIProviderKind
    public var status: AIFeatureStatus
    public var detail: String
    public var privacy: String
    public var useCases: [String]
    public var inputs: [String]
    public var outputs: [String]
    public var nextMilestone: String

    public init(
        id: String,
        title: String,
        category: String,
        provider: AIProviderKind,
        status: AIFeatureStatus,
        detail: String,
        privacy: String,
        useCases: [String],
        inputs: [String] = [],
        outputs: [String] = [],
        nextMilestone: String = ""
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.provider = provider
        self.status = status
        self.detail = detail
        self.privacy = privacy
        self.useCases = useCases
        self.inputs = inputs
        self.outputs = outputs
        self.nextMilestone = nextMilestone
    }
}

public struct LocalMachineProfile: Sendable, Equatable, Codable {
    public var chipName: String
    public var memoryGB: Double
    public var osVersion: String

    public init(chipName: String, memoryGB: Double, osVersion: String) {
        self.chipName = chipName
        self.memoryGB = memoryGB
        self.osVersion = osVersion
    }

    public static var current: LocalMachineProfile {
        LocalMachineProfile(
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    public var displayMemory: String {
        "\(Int(memoryGB.rounded())) GB"
    }

    public var isAppleSilicon: Bool {
        chipName.localizedCaseInsensitiveContains("Apple")
    }

    private static func sysctlString(_ key: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        if buffer.last == 0 {
            buffer.removeLast()
        }
        return String(decoding: buffer.map(UInt8.init(bitPattern:)), as: UTF8.self)
        #else
        return nil
        #endif
    }
}

public enum MLXCompatibilityTier: String, CaseIterable, Sendable, Codable {
    case worksWell
    case works
    case heavy
    case notRecommended
    case unknown

    public var displayName: String {
        switch self {
        case .worksWell: return "Works well"
        case .works: return "Works"
        case .heavy: return "Heavy"
        case .notRecommended: return "Not recommended"
        case .unknown: return "Unknown"
        }
    }

    public var score: Int {
        switch self {
        case .worksWell: return 0
        case .works: return 1
        case .heavy: return 2
        case .unknown: return 3
        case .notRecommended: return 4
        }
    }
}

public enum MLXDownloadState: String, CaseIterable, Sendable, Codable {
    case notDownloaded
    case queued
    case downloading
    case installed
    case failed

    public var displayName: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .installed: return "Installed"
        case .failed: return "Failed"
        }
    }
}

public struct MLXModelCandidate: Identifiable, Sendable, Equatable, Codable {
    public var id: String { repoID }
    public var repoID: String
    public var title: String
    public var parameterCountB: Double
    public var quantization: String
    public var approximateDownloadGB: Double
    public var modality: String
    public var license: String
    public var recommendedUse: String
    public var compatibility: MLXCompatibilityTier
    public var compatibilityReason: String
    public var downloadState: MLXDownloadState
    public var tags: [String]

    public init(
        repoID: String,
        title: String,
        parameterCountB: Double,
        quantization: String,
        approximateDownloadGB: Double,
        modality: String,
        license: String,
        recommendedUse: String,
        compatibility: MLXCompatibilityTier = .unknown,
        compatibilityReason: String = "",
        downloadState: MLXDownloadState = .notDownloaded,
        tags: [String]
    ) {
        self.repoID = repoID
        self.title = title
        self.parameterCountB = parameterCountB
        self.quantization = quantization
        self.approximateDownloadGB = approximateDownloadGB
        self.modality = modality
        self.license = license
        self.recommendedUse = recommendedUse
        self.compatibility = compatibility
        self.compatibilityReason = compatibilityReason
        self.downloadState = downloadState
        self.tags = tags
    }
}

public enum MLXModelCatalog {
    public static func defaultCandidates(for profile: LocalMachineProfile = .current) -> [MLXModelCandidate] {
        baseCandidates
            .map { candidate in
                var annotated = candidate
                let assessment = assess(candidate, for: profile)
                annotated.compatibility = assessment.tier
                annotated.compatibilityReason = assessment.reason
                return annotated
            }
            .sorted {
                if $0.compatibility.score != $1.compatibility.score {
                    return $0.compatibility.score < $1.compatibility.score
                }
                return $0.approximateDownloadGB < $1.approximateDownloadGB
            }
    }

    public static func assess(
        _ candidate: MLXModelCandidate,
        for profile: LocalMachineProfile
    ) -> (tier: MLXCompatibilityTier, reason: String) {
        guard profile.isAppleSilicon else {
            return (.notRecommended, "MLX is designed for Apple silicon; this machine profile does not report an Apple chip.")
        }

        let memory = profile.memoryGB
        let isFourBit = candidate.quantization.localizedCaseInsensitiveContains("4")
        let isVision = candidate.modality.localizedCaseInsensitiveContains("image")
            || candidate.modality.localizedCaseInsensitiveContains("vision")

        if candidate.parameterCountB >= 12 || candidate.approximateDownloadGB >= 7.5 {
            if memory < 24 {
                return (.notRecommended, "This 18 GB-class machine should avoid 12B+ or 7.5 GB+ MLX downloads unless you accept swaps and long cold starts.")
            }
            return (.heavy, "Large model; reserve it for plugged-in desktop sessions.")
        }

        if isVision && memory < 24 {
            return (.heavy, "Multimodal MLX models carry extra memory pressure; usable for experiments, not the default radio assistant on this machine.")
        }

        if isFourBit && candidate.parameterCountB <= 1.5 && candidate.approximateDownloadGB <= 1.5 {
            return (.worksWell, "Small 4-bit model should be responsive on \(profile.chipName) with \(profile.displayMemory) unified memory.")
        }

        if isFourBit && candidate.parameterCountB <= 4.0 && candidate.approximateDownloadGB <= 3.2 {
            return (.worksWell, "Quantized 3B-class model is the best fit for offline RF notes, decoder help, and checklists here.")
        }

        if isFourBit && candidate.parameterCountB <= 5.5 && candidate.approximateDownloadGB <= 4.5 {
            return (.works, "Expected to run locally, though latency and memory use will be more noticeable than the 1B/3B choices.")
        }

        if memory >= 18 && candidate.approximateDownloadGB <= 6.8 {
            return (.heavy, "Likely usable for occasional work, but not ideal as the default assistant on an 18 GB machine.")
        }

        return (.notRecommended, "Download and runtime memory are too high for this local profile.")
    }

    private static let baseCandidates: [MLXModelCandidate] = [
        MLXModelCandidate(
            repoID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            title: "Llama 3.2 1B Instruct 4-bit",
            parameterCountB: 1.0,
            quantization: "4-bit",
            approximateDownloadGB: 0.9,
            modality: "Text",
            license: "Llama 3.2 Community",
            recommendedUse: "Fast offline radio notes, glossary answers, and field checklists.",
            tags: ["fast", "offline", "field"]
        ),
        MLXModelCandidate(
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            title: "Llama 3.2 3B Instruct 4-bit",
            parameterCountB: 3.0,
            quantization: "4-bit",
            approximateDownloadGB: 2.4,
            modality: "Text",
            license: "Llama 3.2 Community",
            recommendedUse: "Default local SignalHive assistant for decoder explanations and session notes.",
            tags: ["recommended", "offline", "assistant"]
        ),
        MLXModelCandidate(
            repoID: "mlx-community/Phi-3.5-mini-instruct-4bit",
            title: "Phi 3.5 Mini Instruct 4-bit",
            parameterCountB: 3.8,
            quantization: "4-bit",
            approximateDownloadGB: 2.5,
            modality: "Text",
            license: "MIT",
            recommendedUse: "Compact reasoning for troubleshooting radio workflows and codeplug checks.",
            tags: ["reasoning", "mit", "assistant"]
        ),
        MLXModelCandidate(
            repoID: "mlx-community/gemma-3-4b-it-4bit",
            title: "Gemma 3 4B IT 4-bit",
            parameterCountB: 5.0,
            quantization: "4-bit",
            approximateDownloadGB: 3.3,
            modality: "Image + text",
            license: "Gemma",
            recommendedUse: "Experimental screenshot or spectrum-image explanations after model-runtime verification.",
            tags: ["multimodal", "experimental"]
        ),
        MLXModelCandidate(
            repoID: "mlx-community/Llama-3.2-3B-Instruct",
            title: "Llama 3.2 3B Instruct F16",
            parameterCountB: 3.0,
            quantization: "F16",
            approximateDownloadGB: 6.43,
            modality: "Text",
            license: "Llama 3.2 Community",
            recommendedUse: "Higher-quality local experiments when memory pressure is acceptable.",
            tags: ["quality", "heavy"]
        ),
        MLXModelCandidate(
            repoID: "mlx-community/gemma-3-12b-it-4bit",
            title: "Gemma 3 12B IT 4-bit",
            parameterCountB: 12.0,
            quantization: "4-bit",
            approximateDownloadGB: 7.8,
            modality: "Image + text",
            license: "Gemma",
            recommendedUse: "Do not make this the default on this machine; keep it for later larger-memory targets.",
            tags: ["large", "not-default"]
        ),
    ]
}

public enum AIWorkbenchFeatureCatalog {
    public static func features(
        classifierValidation: AutoClassifierBundleValidationResult? = nil,
        foundationOnDeviceAvailable: Bool? = nil,
        privateCloudComputeAvailable: Bool? = nil,
        mlxRuntimeAvailable: Bool = false
    ) -> [AIFeature] {
        let classifierStatus: AIFeatureStatus = {
            guard let classifierValidation else { return .needsModel }
            return classifierValidation.passed ? .available : .needsModel
        }()
        let foundationStatus: AIFeatureStatus = foundationOnDeviceAvailable == true ? .available : .readyWhenAvailable
        let pccStatus: AIFeatureStatus = privateCloudComputeAvailable == true ? .available : .requiresEntitlement
        let mlxStatus: AIFeatureStatus = mlxRuntimeAvailable ? .available : .needsModel

        return [
            AIFeature(
                id: "signal-id",
                title: "Real-time signal ID",
                category: "DSP",
                provider: .coreML,
                status: classifierStatus,
                detail: "Classifies IQ windows from the local USB RTL-SDR path first, then feeds the scanner, anomaly detector, and RF coach.",
                privacy: "Runs on device through Core ML.",
                useCases: ["Name unknown signals", "Auto-label recordings", "Trigger decoder suggestions"],
                inputs: ["Local USB RTL-SDR IQ windows", "FFT peaks", "Center frequency", "Bandwidth estimate"],
                outputs: ["Modulation label", "Confidence", "Suggested demodulator", "Recording tags"],
                nextMilestone: "Bundle the real AutoClassify_v2 model or add a verified model downloader with latency and accuracy evidence."
            ),
            AIFeature(
                id: "rf-coach",
                title: "RF coach",
                category: "Operations",
                provider: .foundationOnDevice,
                status: foundationStatus,
                detail: "Explains selected frequencies, FCC license context, demod choices, and likely next steps in plain language.",
                privacy: "Designed for Apple's on-device language model when available.",
                useCases: ["Explain a signal", "Suggest demod settings", "Summarize a licensee"],
                inputs: ["Selected FCC record", "Detected mode", "Signal strength", "Nearby licenses"],
                outputs: ["Plain-language explanation", "Likely service", "Safe monitoring note", "Next action"],
                nextMilestone: "Attach the existing SignalDescriptionEngine to Browse, Search, Scanner, and Trunked detail panes."
            ),
            AIFeature(
                id: "codeplug-assistant",
                title: "Codeplug assistant",
                category: "Programming",
                provider: .foundationOnDevice,
                status: foundationStatus,
                detail: "Reviews channel lists for duplicates, spacing issues, missing tones, and human-readable radio programming notes.",
                privacy: "Runs on device when the Foundation Model is available; falls back to deterministic checks.",
                useCases: ["Check a codeplug", "Generate channel notes", "Spot likely mistakes"],
                inputs: ["Codeplug channels", "Tone/NAC values", "Radio model", "Band-plan rules"],
                outputs: ["Warnings", "Channel grouping", "Radio display names", "Programming checklist"],
                nextMilestone: "Combine deterministic validation with on-device wording and explanations."
            ),
            AIFeature(
                id: "deep-rf-report",
                title: "Deep RF report",
                category: "Research",
                provider: .foundationPrivateCloud,
                status: pccStatus,
                detail: "Uses PCC for longer session summaries, trunking captures, satellite passes, and multi-source reports.",
                privacy: "PCC keeps Apple's privacy model, but requires supported OS, network, entitlement, and quota.",
                useCases: ["Long capture report", "Multi-system comparison", "Field notebook digest"],
                inputs: ["Session timeline", "Decoder events", "Location", "Screenshots or spectra", "Operator notes"],
                outputs: ["Long-form report", "Findings", "Unresolved signals", "Follow-up scan plan"],
                nextMilestone: "Keep disabled until the PCC entitlement and availability probe both pass."
            ),
            AIFeature(
                id: "local-mlx-assistant",
                title: "Offline MLX assistant",
                category: "Local LLM",
                provider: .mlxLocal,
                status: mlxStatus,
                detail: "Downloads MLX-format Hugging Face models with machine-fit annotations before any model is selected.",
                privacy: "Local model files and prompts stay on the machine once downloaded.",
                useCases: ["Offline help", "Decoder recipes", "Experiment logs"],
                inputs: ["Local documentation snippets", "SignalHive state", "Operator prompt"],
                outputs: ["Offline answers", "Step-by-step lab recipes", "Session notes"],
                nextMilestone: "Replace the current queue stub with a verified Hugging Face transfer and MLX inference adapter."
            ),
            AIFeature(
                id: "ais-anomaly",
                title: "AIS pattern-of-life alerts",
                category: "Maritime",
                provider: .rulesEngine,
                status: .available,
                detail: "Flags dark-ship gaps, impossible motion, and other AIS anomalies, then can hand summaries to a language model.",
                privacy: "Deterministic local rules; optional summaries can remain on device.",
                useCases: ["Dark vessel alerts", "Spoofing checks", "Harbor monitoring"],
                inputs: ["AIS messages", "Position history", "Timestamp gaps", "Speed/course changes"],
                outputs: ["Anomaly alert", "Severity", "Track explanation", "Watchlist item"],
                nextMilestone: "Surface existing PatternOfLifeEngine alerts in the decoder and report UI."
            ),
            AIFeature(
                id: "adsb-uat-briefing",
                title: "ADSB/UAT weather briefing",
                category: "Aviation",
                provider: .foundationOnDevice,
                status: foundationStatus,
                detail: "Turns decoded ADS-B, UAT weather, NOTAM-like text, and receiver health into concise radio-room briefings.",
                privacy: "On-device summary target; decoded packets remain local.",
                useCases: ["978 weather digest", "Aircraft activity notes", "Receiver QA"],
                inputs: ["ADS-B aircraft", "UAT weather products", "Receiver stats", "Local airport context"],
                outputs: ["Weather digest", "Traffic summary", "Receiver health notes", "Interesting aircraft"],
                nextMilestone: "Add a dump1090/dump978-style session model and summarize it on device."
            ),
            AIFeature(
                id: "satellite-pass-assistant",
                title: "Satellite pass assistant",
                category: "Satellite",
                provider: .foundationOnDevice,
                status: .planned,
                detail: "Will annotate Meteor LRPT capture quality and explain image products once passes can be recorded and decoded.",
                privacy: "Planned on-device analysis of local pass data.",
                useCases: ["Pass plan notes", "LRPT capture notes", "Image QA"],
                inputs: ["TLE/pass data", "RTL-SDR settings", "Audio/image product", "Signal quality"],
                outputs: ["Pass plan", "Capture checklist", "Image quality notes", "Retune recommendation"],
                nextMilestone: "Record and decode Meteor LRPT passes before LLM summaries (pass prediction already exists)."
            ),
            AIFeature(
                id: "semantic-fcc-search",
                title: "Semantic FCC search",
                category: "Data",
                provider: .coreML,
                status: .planned,
                detail: "Local embeddings for natural-language searches across licensees, emissions, locations, and radio services.",
                privacy: "Target is local indexes built from installed packs.",
                useCases: ["Find school buses near me", "Find trunked-like emissions", "Cluster local services"],
                inputs: ["Installed FCC packs", "Emission designators", "Geo/site data", "User query"],
                outputs: ["Ranked results", "Reason for match", "Service clusters", "Saved scan list"],
                nextMilestone: "Build a local embedding/index prototype and compare against exact database search."
            ),
            AIFeature(
                id: "interference-hunter",
                title: "Interference hunter",
                category: "Field Work",
                provider: .coreML,
                status: .planned,
                detail: "Learns recurring carriers, burst patterns, and noise-floor changes to help track interference sources over time.",
                privacy: "Local signal fingerprints and maps only.",
                useCases: ["Find recurring noise", "Compare locations", "Prioritize hunts"],
                inputs: ["Spectrum snapshots", "GPS/location", "Time of day", "Receiver gain"],
                outputs: ["Fingerprint", "Heat map point", "Likely recurrence window", "Hunt checklist"],
                nextMilestone: "Persist spectrum snapshots and implement deterministic baselines before training any model."
            ),
            AIFeature(
                id: "decoder-router",
                title: "Decoder router",
                category: "DSP",
                provider: .coreML,
                status: .planned,
                detail: "Uses signal classification and protocol hints to choose the best local USB demodulator/decoder path, with network/Pi sources as alternate inputs later.",
                privacy: "Local DSP decisioning only.",
                useCases: ["Auto-pick decoder", "Reduce trial-and-error", "Explain failures"],
                inputs: ["Local USB RTL-SDR stream", "Classifier result", "Bandwidth", "Symbol-rate estimate", "Frequency band"],
                outputs: ["Decoder candidate", "Confidence", "Required hardware path", "Failure reason"],
                nextMilestone: "Map every implemented decoder to required signal traits and add confidence scoring."
            ),
            AIFeature(
                id: "hardware-source-advisor",
                title: "Hardware source advisor",
                category: "Hardware",
                provider: .rulesEngine,
                status: .planned,
                detail: "Keeps direct USB RTL-SDR on the Mac as the primary path, then chooses rtl_tcp/OpenWebRX/Raspberry Pi routes only when remote hardware is configured.",
                privacy: "Local hardware inventory and user-configured network endpoints only.",
                useCases: ["Prefer local USB", "Switch to Pi receiver", "Explain missing samples"],
                inputs: ["USB device list", "Driver status", "Configured Pi endpoints", "Sample-rate needs"],
                outputs: ["Preferred source", "Driver warning", "Remote fallback option", "Setup checklist"],
                nextMilestone: "Expose source priority in Settings and Scanner: Local USB first, network/Pi optional."
            ),
        ]
    }
}

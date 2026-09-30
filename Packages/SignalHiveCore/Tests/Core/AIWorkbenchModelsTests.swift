import Testing
@testable import SignalHiveCore

@Suite struct AIWorkbenchModelsTests {
    private let m3Pro18GB = LocalMachineProfile(
        chipName: "Apple M3 Pro",
        memoryGB: 18,
        osVersion: "Version 27.0.1"
    )

    @Test func mlxCatalogRanksSmallQuantizedModelsForThisMachine() {
        let models = MLXModelCatalog.defaultCandidates(for: m3Pro18GB)

        #expect(models.first?.repoID == "mlx-community/Llama-3.2-1B-Instruct-4bit")
        #expect(models.first { $0.repoID == "mlx-community/Llama-3.2-3B-Instruct-4bit" }?.compatibility == .worksWell)
        #expect(models.first { $0.repoID == "mlx-community/Phi-3.5-mini-instruct-4bit" }?.compatibility == .worksWell)
    }

    @Test func mlxCatalogMarksLargeModelsAsBadFitForEighteenGB() {
        let models = MLXModelCatalog.defaultCandidates(for: m3Pro18GB)

        #expect(models.first { $0.repoID == "mlx-community/Llama-3.2-3B-Instruct" }?.compatibility == .heavy)
        #expect(models.first { $0.repoID == "mlx-community/gemma-3-12b-it-4bit" }?.compatibility == .notRecommended)
    }

    @Test func nonAppleSiliconIsNotRecommendedForMLX() {
        var candidate = MLXModelCatalog.defaultCandidates(for: m3Pro18GB)[0]
        let profile = LocalMachineProfile(
            chipName: "Intel Core i9",
            memoryGB: 64,
            osVersion: "Version 27.0.1"
        )

        let assessment = MLXModelCatalog.assess(candidate, for: profile)
        candidate.compatibility = assessment.tier

        #expect(candidate.compatibility == .notRecommended)
    }

    @Test func aiFeatureCatalogReflectsClassifierReadiness() {
        let passingValidation = AutoClassifierBundleValidationResult(
            assetStatus: AutoClassifierBundledAssetStatus(
                contract: .current,
                contractSource: "test",
                searchRoots: [],
                manifestURL: nil,
                modelURL: nil,
                benchmarkURL: nil,
                evaluationURL: nil
            ),
            benchmark: nil,
            evaluation: nil,
            issues: []
        )

        let features = AIWorkbenchFeatureCatalog.features(
            classifierValidation: passingValidation,
            foundationOnDeviceAvailable: false,
            privateCloudComputeAvailable: false,
            mlxRuntimeAvailable: false
        )

        #expect(features.first { $0.id == "signal-id" }?.status == .available)
        #expect(features.first { $0.id == "rf-coach" }?.status == .readyWhenAvailable)
        #expect(features.first { $0.id == "deep-rf-report" }?.status == .requiresEntitlement)
        #expect(features.first { $0.id == "local-mlx-assistant" }?.status == .needsModel)
    }
}

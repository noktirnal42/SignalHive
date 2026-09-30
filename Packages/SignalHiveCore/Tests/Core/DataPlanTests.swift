import Testing
import Foundation
@testable import SignalHiveCore

struct DataPlanTests {
    private let states: [StateAvailability] = [
        StateAvailability(code: "CA", name: "California", status: .notInstalled(sizeBytes: 30_000_000)),
        StateAvailability(code: "MO", name: "Missouri", status: .notInstalled(sizeBytes: 9_000_000)),
        StateAvailability(code: "TX", name: "Texas", status: .notInstalled(sizeBytes: nil)),
        StateAvailability(code: "WA", name: "Washington", status: .installed(snapshot: "2026-09-01")),
        StateAvailability(code: "OR", name: "Oregon", status: .downloading(progress: 0.3)),
        StateAvailability(code: "NV", name: "Nevada", status: .failed(reason: "checksum")),
        StateAvailability(code: "UT", name: "Utah", status: .notInstalled(sizeBytes: nil)),
    ]
    private let services: [ULSService] = [.lmPriv, .lmComm]

    private func makePlan(_ codes: Set<String>, hosted: Bool = true, preference: DataSourcePreference = .automatic,
                      refresh: Bool = false) -> DataPlan {
        DataPlan.make(requested: codes, states: states, hostedAvailable: hosted, preference: preference, services: services,
                      refreshInstalled: refresh)
    }

    @Test func hostedPacksAreDownloadedAndTheRestAreBuilt() {
        let plan = makePlan(["CA", "MO", "TX"])
        #expect(plan.downloads.map(\.code) == ["CA", "MO"])
        #expect(plan.builds.map(\.code) == ["TX"])
        #expect(plan.downloadBytes == 39_000_000)
        #expect(plan.buildDownloadBytes == Int64(403 + 78) * 1_048_576)
        #expect(plan.totalBytes == plan.downloadBytes + plan.buildDownloadBytes)
    }

    @Test func manyBuiltStatesShareOneArchiveDownload() {
        let single = makePlan(["TX"])
        let double = makePlan(["TX", "UT"])
        #expect(double.builds.count == 2)
        #expect(double.buildDownloadBytes == single.buildDownloadBytes, "the archives are fetched once however many states are built")
        #expect(double.bytesSavedByOnePass == single.buildDownloadBytes)
        #expect(single.bytesSavedByOnePass == 0)
        #expect(double.summary.contains("Build 2 states from one download"))
    }

    @Test func nothingIsBuiltSoNothingIsDownloadedFromTheFCC() {
        let plan = makePlan(["CA"])
        #expect(plan.builds.isEmpty && plan.buildDownloadBytes == 0)
    }

    @Test func installedAndBusyStatesAreSkipped() {
        let plan = makePlan(["WA", "OR", "CA"])
        #expect(plan.downloads.map(\.code) == ["CA"])
        #expect(plan.skipped.map(\.code) == ["WA", "OR"])
        #expect(plan.items.first { $0.code == "WA" }?.route == .skip(.alreadyInstalled(snapshot: "2026-09-01")))
        #expect(plan.items.first { $0.code == "OR" }?.route == .skip(.inProgress))
    }

    @Test func refreshingRedoesInstalledStatesButNotBusyOnes() {
        let plan = makePlan(["WA", "OR"], refresh: true)
        #expect(plan.items.first { $0.code == "WA" }?.route == .download)
        #expect(plan.items.first { $0.code == "OR" }?.route == .skip(.inProgress))
    }

    @Test func aFailedStateIsTriedAgain() {
        #expect(makePlan(["NV"]).downloads.map(\.code) == ["NV"])
        #expect(makePlan(["NV"], hosted: false).builds.map(\.code) == ["NV"])
    }

    @Test func withoutTheHostedListEverythingIsBuilt() {
        let plan = makePlan(["CA", "MO"], hosted: false)
        #expect(plan.downloads.isEmpty)
        #expect(plan.builds.map(\.code) == ["CA", "MO"])
    }

    @Test func buildingCanBeForced() {
        let plan = makePlan(["CA", "MO"], preference: .buildOnThisDevice)
        #expect(plan.builds.map(\.code) == ["CA", "MO"])
        #expect(plan.downloadBytes == 0)
    }

    @Test func statesComeInTheOrderOfTheList() {
        #expect(makePlan(["UT", "CA", "MO"]).items.map(\.code) == ["CA", "MO", "UT"])
        #expect(makePlan(["ZZ"]).items.isEmpty, "a code nobody lists is ignored")
    }

    @Test func theSummaryDescribesTheJob() {
        #expect(makePlan([]).summary == "Choose the states you want.")
        #expect(makePlan(["WA"]).summary == "Everything chosen is already installed or being installed.")
        let text = makePlan(["CA", "MO", "TX", "WA"]).summary
        #expect(text.contains("Download 2 hosted packs"))
        #expect(text.contains("Build 1 state from one download"))
        #expect(text.contains("1 already installed or in progress: skipped."))
    }
}

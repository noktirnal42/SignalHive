import Testing
import Foundation
@testable import SignalHiveCore

struct WorkshopCatalogTests {
    private func item(_ id: String, _ env: WorkshopEnvironment) throws -> WorkshopItem {
        try #require(WorkshopCatalog.items(for: env).first { $0.id == id }, "no item \(id)")
    }

    private let bare = WorkshopEnvironment()
    private let bench = WorkshopEnvironment(installedPacks: 3, rtlsdrDongles: 2, rtlsdrSummary: "2 RTL-SDR dongles found: A, B.",
                                            networkSources: 1, tools: ["dsdccx"], codeplugChannels: 12,
                                            demodModes: ["AM", "NFM"], aiModelsInstalled: 1)

    @Test func itemIdentitiesAreUnique() {
        let ids = WorkshopCatalog.items(for: bench).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(WorkshopCatalog.items(for: bare).map(\.id)) == Set(ids), "the same items exist whatever the machine")
    }

    @Test func everySectionHasItems() {
        for section in WorkshopSection.allCases {
            #expect(!WorkshopCatalog.items(in: section, for: bare).isEmpty)
        }
    }

    @Test func aBareMachineNeedsSetupWhereHardwareOrDataIsRequired() throws {
        #expect(try item("fcc", bare).status == .needsSetup)
        #expect(try item("fcc", bare).setup != nil)
        #expect(try item("spectrum", bare).status == .needsSetup)
        #expect(try item("adsb", bare).status == .needsSetup)
        #expect(try item("uat", bare).status == .needsSetup)
        #expect(try item("rtlsdr", bare).status == .needsSetup)
        #expect(try item("network", bare).status == .needsSetup)
        #expect(try item("hackrf", bare).status == .needsSetup)
    }

    @Test func whatNeedsNothingIsReadyOnABareMachine() throws {
        for id in ["codeplug", "trunked", "ailab"] {
            let entry = try item(id, bare)
            #expect(entry.status == .ready, "\(id) needs neither data nor hardware")
            #expect(entry.setup == nil)
        }
    }

    @Test func aBenchWithEverythingHasNothingLeftToSetUpInTheWorkflows() throws {
        for entry in WorkshopCatalog.items(in: .workflows, for: bench) {
            #expect(entry.status == .ready, "\(entry.id)")
            #expect(entry.setup == nil)
        }
        #expect(try item("fcc", bench).detail.contains("3 state packs"))
        #expect(try item("codeplug", bench).detail.contains("12 channels"))
        #expect(try item("ailab", bench).detail.contains("1 on-device model downloaded"))
        #expect(try item("demod", bench).detail.contains("AM, NFM"))
    }

    @Test func aSingleDongleIsToldItCannotDoBothBands() throws {
        let single = WorkshopEnvironment(rtlsdrDongles: 1, rtlsdrSummary: "RTL-SDR found: A.")
        #expect(try item("adsb", single).detail.contains("One dongle runs one band at a time"))
        #expect(try item("adsb", bench).detail.contains("One dongle runs one band at a time") == false)
    }

    @Test func aNetworkSourceAloneRunsTheScannerButNotTheAirTools() throws {
        let remote = WorkshopEnvironment(networkSources: 1)
        #expect(try item("spectrum", remote).status == .ready)
        #expect(try item("adsb", remote).status == .needsSetup)
    }

    @Test func decodersTheAppDoesNotUseAreNotCalledAvailable() throws {
        for id in ["acars", "ais", "morse", "dmr", "paging", "weak"] {
            #expect(try item(id, bench).status == .notConnected, "\(id) is in the library but not in the app")
        }
        #expect(try item("otherSDR", bench).status == .notConnected)
        #expect(try item("dmr", bench).setup == "dsdccx is installed.")
        #expect(try item("dmr", bare).setup == nil)
    }

    @Test func plannedThingsArePlanned() {
        #expect(WorkshopCatalog.items(in: .planned, for: bare).allSatisfy { $0.status == .planned })
    }

    @Test func tilesLeadToScreensThatExist() throws {
        #expect(try item("fcc", bare).destination == .browse)
        #expect(try item("airmap", bare).destination == .airMap)
        #expect(try item("airdata", bare).destination == .airData)
        #expect(try item("trunked", bare).destination == .trunked)
        #expect(try item("codeplug", bare).destination == .codeplug)
        #expect(try item("ailab", bare).destination == .aiLab)
        #expect(try item("apt", bare).destination == nil)
    }

    @Test func theCountsFollowTheStatuses() {
        let bareCount = WorkshopCatalog.readiness(for: bare)
        let benchCount = WorkshopCatalog.readiness(for: bench)
        #expect(bareCount.implemented == benchCount.implemented)
        #expect(bareCount.ready < benchCount.ready)
        #expect(WorkshopCatalog.workingDecoders(for: bare) == 2, "only ADS-B and UAT decode anything in the app")
    }

    @Test func statusesAllHaveLabels() {
        for status in WorkshopStatus.allCases { #expect(!status.label.isEmpty) }
    }
}

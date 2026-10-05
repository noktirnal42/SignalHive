import Testing
import Foundation
@testable import SignalHiveCore

// The Workshop is a launchpad: every tile ends in a verb, and a tile that is not ready offers the step that makes it ready.
struct WorkshopActionTests {
    private let bare = WorkshopEnvironment()
    private let bench = WorkshopEnvironment(installedPacks: 3, rtlsdrDongles: 2, rtlsdrSummary: "2 RTL-SDR dongles found: A, B.",
                                            networkSources: 1, tools: ["dsdccx"], codeplugChannels: 12,
                                            demodModes: ["AM", "NFM"], aiModelsInstalled: 1)

    private func item(_ id: String, _ env: WorkshopEnvironment) throws -> WorkshopItem {
        try #require(WorkshopCatalog.items(for: env).first { $0.id == id }, "no item \(id)")
    }

    // MARK: Item rules

    @Test func everyItemThatWorksOrNeedsSetupHasAnAction() {
        for env in [bare, bench] {
            for entry in WorkshopCatalog.items(for: env) where entry.status == .ready || entry.status == .needsSetup {
                #expect(entry.action != nil, "\(entry.id) is \(entry.status.label) but does nothing when pressed")
            }
        }
    }

    @Test func everyItemThatNeedsSetupOffersTheFix() {
        for env in [bare, bench] {
            for entry in WorkshopCatalog.items(for: env) where entry.status == .needsSetup {
                guard case .fix = entry.action else {
                    Issue.record("\(entry.id) needs setup but its action is \(String(describing: entry.action))")
                    continue
                }
            }
        }
    }

    @Test func aReadyItemOpensOrLaunchesAPanel() {
        for entry in WorkshopCatalog.items(for: bench) where entry.status == .ready {
            switch entry.action {
            case .open, .launch: break
            default: Issue.record("\(entry.id) is ready but its action is \(String(describing: entry.action))")
            }
        }
    }

    @Test func anItemTheAppCannotRunExplainsItselfInsteadOfOpeningAPanel() {
        for env in [bare, bench] {
            for entry in WorkshopCatalog.items(for: env) where entry.status == .notConnected {
                guard case let .learn(text) = entry.action else {
                    Issue.record("\(entry.id) is not connected but its action is \(String(describing: entry.action))")
                    continue
                }
                #expect(!text.isEmpty, "\(entry.id)")
                #expect(entry.destination == nil, "\(entry.id) must not lead to a panel that cannot do it")
            }
        }
    }

    @Test func plannedItemsLeaveTheHomeGridForTheRoadmap() {
        let all = WorkshopCatalog.items(for: bare)
        let home = WorkshopCatalog.homeItems(for: bare)
        let roadmap = WorkshopCatalog.roadmapItems(for: bare)

        #expect(home.allSatisfy { $0.status != .planned })
        #expect(!roadmap.isEmpty)
        #expect(roadmap.allSatisfy { $0.status == .planned })
        #expect(home.count + roadmap.count == all.count)
    }

    // MARK: Which action, for which item

    @Test func eachMissingThingGetsItsOwnFix() throws {
        #expect(try item("fcc", bare).action == .fix(.getFCCData))
        #expect(try item("spectrum", bare).action == .fix(.usbHelp))
        #expect(try item("rtlsdr", bare).action == .fix(.usbHelp))
        #expect(try item("network", bare).action == .fix(.addNetworkSource))
        #expect(try item("hackrf", bare).action == .fix(.installTool("libhackrf")))
    }

    @Test func theAirToolsStartTheirReceiverWhenADongleIsPresent() throws {
        #expect(try item("adsb", bench).action == .launch(.airMap, .listenADSB1090))
        #expect(try item("airmap", bench).action == .launch(.airMap, .listenADSB1090))
        #expect(try item("uat", bench).action == .launch(.airData, .listenUAT978))
        #expect(try item("airdata", bench).action == .launch(.airData, .listenUAT978))
    }

    @Test func theDecoderTilesOpenTheirOwnDecoder() throws {
        for id in ["acars", "ais", "morse"] {
            #expect(try item(id, bare).action == .launch(.decoderHub, .decoder(id)), "\(id)")
        }
    }

    @Test func destinationFollowsTheAction() throws {
        #expect(try item("fcc", bench).destination == .browse)
        #expect(try item("adsb", bench).destination == .airMap)
        #expect(try item("acars", bench).destination == .decoderHub)
        #expect(try item("fcc", bare).destination == nil, "a fix stays on the Workshop")
        #expect(try item("ism", bare).destination == nil)
    }

    @Test func everyActionHasAButtonLabel() {
        for env in [bare, bench] {
            for entry in WorkshopCatalog.items(for: env) {
                if let action = entry.action { #expect(!action.label.isEmpty, "\(entry.id)") }
                #expect(entry.actionLabel == entry.action?.label)
            }
        }
        #expect(WorkshopAction.open(.browse).label == "Open")
        #expect(WorkshopAction.fix(.getFCCData).label == "Get data")
        #expect(WorkshopAction.learn("x").label == "Details")
    }

    // MARK: Quick actions

    @Test func withALiveSourceNOAAWeatherStartsListening() throws {
        let weather = try #require(WorkshopCatalog.quickActions(for: bench).first { $0.id == "noaa-weather" })
        #expect(weather.action == .launch(.scanner, .scannerTune(mhz: 162.55, mode: .nfm)))
        #expect(!weather.needsSetup)
    }

    @Test func withoutASourceTheListenActionsOfferTheFixInstead() throws {
        for id in ["noaa-weather", "airband"] {
            let quick = try #require(WorkshopCatalog.quickActions(for: bare).first { $0.id == id })
            #expect(quick.action == .fix(.usbHelp), "\(id)")
            #expect(quick.needsSetup, "\(id)")
        }
    }

    @Test func aNetworkSourceCanListenButCannotTrackAircraft() throws {
        let remote = WorkshopEnvironment(networkSources: 1)
        let listen = try #require(WorkshopCatalog.quickActions(for: remote).first { $0.id == "noaa-weather" })
        let track = try #require(WorkshopCatalog.quickActions(for: remote).first { $0.id == "track-aircraft" })
        #expect(!listen.needsSetup)
        #expect(track.needsSetup, "ADS-B decodes from an RTL-SDR dongle, not from a network source")
        #expect(try #require(WorkshopCatalog.quickActions(for: bench).first { $0.id == "track-aircraft" }).action
                == .launch(.airMap, .listenADSB1090))
    }

    @Test func openCodeplugOnlyAppearsWhenThereIsOne() throws {
        #expect(WorkshopCatalog.quickActions(for: bare).contains { $0.id == "open-codeplug" } == false)
        let open = try #require(WorkshopCatalog.quickActions(for: bench).first { $0.id == "open-codeplug" })
        #expect(open.action == .open(.codeplug))
        #expect(open.title.contains("12"))
    }

    @Test func gettingStateDataIsAlwaysOffered() throws {
        for env in [bare, bench] {
            let data = try #require(WorkshopCatalog.quickActions(for: env).first { $0.id == "state-data" })
            #expect(data.action == .fix(.getFCCData))
            #expect(!data.needsSetup)
        }
    }

    @Test func quickActionIdentitiesAreUnique() {
        let ids = WorkshopCatalog.quickActions(for: bench).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

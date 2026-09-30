import Testing
import Foundation
@testable import SignalHiveCore

// MARK: - Fixtures

/// The shape OpenMHz's own server sends for /systems.
private let systemsJSON = """
{"success": true, "systems": [
  {"name": "Santa Clara County Sheriff", "shortName": "sccsd", "systemType": "p25", "city": "San Jose", "county": "Santa Clara",
   "state": "CA", "country": "US", "description": "Countywide P25", "callAvg": 42.5, "clientCount": 3, "active": true,
   "lastActive": "2026-09-30T12:34:56.789Z"},
  {"name": "WMATA Bus", "shortName": "wmata", "systemType": "smartnet", "city": "Washington", "state": "DC", "country": "US",
   "callAvg": "7", "clientCount": "0", "active": false, "lastActive": "2026-09-01T00:00:00Z"},
  {"name": "No short name here"},
  {"shortName": "bare", "systemType": "dmr"}
]}
"""

/// The shape OpenMHz's own server sends for /<system>/talkgroups: an object keyed by number.
private let talkgroupsJSON = """
{"talkgroups": {
  "101": {"_id": "a", "num": 101, "alpha": "SO Disp", "description": "Sheriff Dispatch", "tag": "Law Dispatch", "group": "Sheriff"},
  "2002": {"_id": "b", "num": 2002, "alpha": "FD Tac 2", "description": "Fire Tactical 2", "tag": "Fire-Tac", "group": "Fire"},
  "3": {"_id": "c", "num": 3, "alpha": "", "description": "Public Works Yard"},
  "oops": {"note": "no number at all"}
}}
"""

private func data(_ text: String) -> Data { Data(text.utf8) }

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("signalhive-trunked-\(UUID().uuidString)", isDirectory: true)
}

private func response(_ url: URL, status: Int = 200) -> URLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// A client whose answers are looked up by path; a missing path fails like an offline network.
private func stubClient(_ answers: [String: (Int, String)]) -> OpenMHzClient {
    OpenMHzClient(baseURL: URL(string: "https://example.test")!) { request in
        let url = request.url!
        guard let (status, body) = answers[url.path] else { throw URLError(.notConnectedToInternet) }
        return (Data(body.utf8), response(url, status: status))
    }
}

// MARK: - Parser

struct OpenMHzParserTests {
    @Test func systemsAreReadFromTheServersOwnShape() throws {
        let systems = try OpenMHzParser.systems(from: data(systemsJSON))
        #expect(systems.map(\.shortName) == ["sccsd", "wmata", "bare"], "an entry without a short name is dropped")

        let sheriff = try #require(systems.first)
        #expect(sheriff.name == "Santa Clara County Sheriff")
        #expect(sheriff.typeLabel == "P25")
        #expect(sheriff.location == "San Jose, Santa Clara, CA")
        #expect(sheriff.callsPerHour == 42.5)
        #expect(sheriff.listeners == 3)
        #expect(sheriff.isActive)
        #expect(sheriff.lastActive != nil, "fractional seconds are accepted")
        #expect(sheriff.details == "Countywide P25")
    }

    @Test func numbersSentAsTextAndMissingFieldsAreTolerated() throws {
        let systems = try OpenMHzParser.systems(from: data(systemsJSON))
        let bus = try #require(systems.first { $0.shortName == "wmata" })
        #expect(bus.callsPerHour == 7)
        #expect(bus.listeners == 0)
        #expect(!bus.isActive)
        #expect(bus.typeLabel == "SmartNet")
        #expect(bus.lastActive != nil, "plain seconds are accepted")

        let bare = try #require(systems.first { $0.shortName == "bare" })
        #expect(bare.name == "bare", "the short name stands in for a missing name")
        #expect(bare.isActive, "a system that does not say is assumed active")
        #expect(bare.location.isEmpty)
        #expect(bare.lastActive == nil)
    }

    @Test func aBareArrayAndAKeyedObjectAreAlsoSystemLists() throws {
        let array = try OpenMHzParser.systems(from: data(#"[{"shortName": "a", "name": "A"}, {"short_name": "b", "name": "B"}]"#))
        #expect(array.map(\.shortName) == ["a", "b"])

        let keyed = try OpenMHzParser.systems(from: data(#"{"systems": {"a": {"shortName": "a"}}}"#))
        #expect(keyed.map(\.shortName) == ["a"])
    }

    @Test func aSystemListThatIsNotOneIsAnError() {
        #expect(throws: OpenMHzError.self) { try OpenMHzParser.systems(from: data("not json")) }
        #expect(throws: OpenMHzError.self) { try OpenMHzParser.systems(from: data(#"{"success": false}"#)) }
        #expect(throws: OpenMHzError.self) { try OpenMHzParser.systems(from: data("42")) }
    }

    @Test func talkgroupsAreReadAndSortedByNumber() throws {
        let talkgroups = try OpenMHzParser.talkgroups(from: data(talkgroupsJSON), system: "sccsd")
        #expect(talkgroups.map(\.code) == [3, 101, 2002], "an entry with no number is dropped, the rest are in numeric order")
        #expect(talkgroups.allSatisfy { $0.systemShortName == "sccsd" })

        let dispatch = try #require(talkgroups.first { $0.code == 101 })
        #expect(dispatch.alphaTag == "SO Disp")
        #expect(dispatch.descriptionText == "Sheriff Dispatch")
        #expect(dispatch.tag == "Law Dispatch")
        #expect(dispatch.group == "Sheriff")
        #expect(dispatch.id == "sccsd-101")
    }

    @Test func aTalkgroupWithoutATagIsNamedByItsDescription() throws {
        let talkgroups = try OpenMHzParser.talkgroups(from: data(talkgroupsJSON), system: "sccsd")
        let yard = try #require(talkgroups.first { $0.code == 3 })
        #expect(yard.alphaTag.isEmpty)
        #expect(yard.displayName == "Public Works Yard")
        #expect(TrunkedTalkgroup(systemShortName: "x", code: 9, alphaTag: "", descriptionText: "").displayName == "TG 9")
    }

    @Test func talkgroupsAlsoComeAsAnArrayWithOtherFieldNames() throws {
        let json = #"""
        [{"decimal": 10, "alphaTag": "PD 1", "desc": "Police 1", "count": 5},
         {"num": "11", "alpha_tag": "PD 2", "des": "Police 2"},
         {"id": 12, "alpha": "PD 3"}]
        """#
        let talkgroups = try OpenMHzParser.talkgroups(from: data(json), system: "x")
        #expect(talkgroups.map(\.code) == [10, 11, 12])
        #expect(talkgroups.map(\.alphaTag) == ["PD 1", "PD 2", "PD 3"])
        #expect(talkgroups[0].descriptionText == "Police 1")
        #expect(talkgroups[0].callCount == 5)
        #expect(talkgroups[1].descriptionText == "Police 2")
    }

    @Test func aTalkgroupListThatIsNotOneIsAnError() {
        #expect(throws: OpenMHzError.self) { try OpenMHzParser.talkgroups(from: data("nope"), system: "x") }
        #expect(throws: OpenMHzError.self) { try OpenMHzParser.talkgroups(from: data("7"), system: "x") }
    }
}

// MARK: - Client

struct OpenMHzClientTests {
    @Test func theClientAsksTheRightPathsAndParses() async throws {
        let client = stubClient(["/systems": (200, systemsJSON), "/sccsd/talkgroups": (200, talkgroupsJSON)])
        let systems = try await client.systems()
        #expect(systems.count == 3)
        let talkgroups = try await client.talkgroups(systemShortName: "sccsd")
        #expect(talkgroups.count == 3)
    }

    @Test func aBadStatusIsARequestFailure() async {
        let client = stubClient(["/systems": (503, "busy")])
        await #expect(throws: OpenMHzError.self) { try await client.systems() }
    }

    @Test func aDeadNetworkIsARequestFailure() async {
        let client = stubClient([:])
        await #expect(throws: OpenMHzError.self) { try await client.systems() }
    }

    @Test func systemNamesAreEscapedInThePath() async throws {
        let seen = PathRecorder()
        let client = OpenMHzClient(baseURL: URL(string: "https://example.test")!) { request in
            seen.record(request.url!.absoluteString)
            return (Data(#"{"talkgroups": {}}"#.utf8), response(request.url!))
        }
        _ = try await client.talkgroups(systemShortName: "a b/c")
        #expect(seen.paths == ["https://example.test/a%20b%2Fc/talkgroups"])
    }
}

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ path: String) { lock.lock(); stored.append(path); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - Cache and repository

struct TrunkedCacheTests {
    @Test func systemsAndTalkgroupsRoundTripThroughTheCache() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TrunkedCache(directory: directory)
        let saved = Date(timeIntervalSinceReferenceDate: 800_000_000)

        #expect(cache.loadSystems() == nil, "nothing is cached to begin with")
        // Whole-second dates, so equality does not depend on how a fraction of a second prints.
        let systems = try OpenMHzParser.systems(from: data(systemsJSON)).map { system -> TrunkedSystem in
            var whole = system
            whole.lastActive = system.lastActive.map { Date(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate.rounded()) }
            return whole
        }
        try cache.saveSystems(systems, at: saved)
        let loaded = try #require(cache.loadSystems())
        #expect(loaded.systems == systems)
        #expect(loaded.savedAt == saved)

        let talkgroups = try OpenMHzParser.talkgroups(from: data(talkgroupsJSON), system: "sccsd")
        try cache.saveTalkgroups(talkgroups, system: "sccsd", at: saved)
        #expect(cache.loadTalkgroups(system: "sccsd")?.talkgroups == talkgroups)
        #expect(cache.loadTalkgroups(system: "other") == nil, "each system has its own copy")
    }

    @Test func aDamagedCacheFileReadsAsNothing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not what we wrote".utf8).write(to: directory.appendingPathComponent("systems.json"))
        #expect(TrunkedCache(directory: directory).loadSystems() == nil)
    }

    @Test func systemNamesCannotEscapeTheCacheDirectory() {
        let cache = TrunkedCache(directory: temporaryDirectory())
        let name = cache.fileName(forTalkgroupsOf: "../../etc/passwd")
        #expect(!name.contains("/") && !name.contains(".."))
        #expect(cache.fileName(forTalkgroupsOf: "sccsd") == "talkgroups-sccsd.json")
    }
}

struct TrunkedRepositoryTests {
    @Test func aSuccessfulLoadIsFreshAndIsRemembered() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TrunkedCache(directory: directory)
        let repository = TrunkedRepository(client: stubClient(["/systems": (200, systemsJSON)]), cache: cache)

        let load = try await repository.systems()
        #expect(load.value.count == 3)
        #expect(!load.isCached && load.networkError == nil)
        #expect(cache.loadSystems()?.systems.count == 3)
    }

    @Test func whenTheNetworkFailsTheLastCopyStandsIn() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TrunkedCache(directory: directory)
        let saved = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try cache.saveSystems(try OpenMHzParser.systems(from: data(systemsJSON)), at: saved)
        try cache.saveTalkgroups(try OpenMHzParser.talkgroups(from: data(talkgroupsJSON), system: "sccsd"), system: "sccsd", at: saved)

        let offline = TrunkedRepository(client: stubClient([:]), cache: cache)
        let systems = try await offline.systems()
        #expect(systems.isCached && systems.savedAt == saved)
        #expect(systems.value.count == 3)
        #expect(systems.networkError != nil)

        let talkgroups = try await offline.talkgroups(system: "sccsd")
        #expect(talkgroups.isCached && talkgroups.value.count == 3)
    }

    @Test func whenTheNetworkAndCacheAreEmptyTheStarterDirectoryKeepsBrowsingUsable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = TrunkedRepository(client: stubClient([:]), cache: TrunkedCache(directory: directory))

        let systems = try await repository.systems()
        #expect(systems.isSeeded)
        #expect(!systems.value.isEmpty)
        #expect(systems.networkError != nil)

        let talkgroups = try await repository.talkgroups(system: "sccsd")
        #expect(talkgroups.isSeeded)
        #expect(talkgroups.value.contains { $0.category == .law })
    }

    @Test func withNoNetworkAndNoCopyTheErrorIsReported() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = TrunkedRepository(client: stubClient([:]), cache: TrunkedCache(directory: directory), seed: nil)
        await #expect(throws: OpenMHzError.self) { try await repository.systems() }
        await #expect(throws: OpenMHzError.self) { try await repository.talkgroups(system: "sccsd") }
    }

    @Test func anEmptyFreshAnswerIsNotConfusedWithAFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = TrunkedRepository(client: stubClient(["/quiet/talkgroups": (200, #"{"talkgroups": {}}"#)]),
                                           cache: TrunkedCache(directory: directory))
        let load = try await repository.talkgroups(system: "quiet")
        #expect(load.value.isEmpty && !load.isCached)
    }
}

// MARK: - Categories

struct TalkgroupCategoryTests {
    private func talkgroup(_ alpha: String = "", _ description: String = "", tag: String = "", group: String = "") -> TrunkedTalkgroup {
        TrunkedTalkgroup(systemShortName: "x", code: 1, alphaTag: alpha, descriptionText: description, tag: tag, group: group)
    }

    static let nameCases: [(String, TalkgroupCategory)] = [
        ("Sheriff Dispatch", .law),
        ("Police Tac 3", .law),
        ("SO Patrol North", .law),
        ("Fire Dispatch", .fire),
        ("Engine 12", .fire),
        ("Hazmat Team", .fire),
        ("EMS Dispatch", .ems),
        ("Medic 4", .ems),
        ("Ambulance Transport", .ems),
        ("Mercy Hospital ER", .hospital),
        ("Public Works Yard", .publicWorks),
        ("Street Maintenance", .publicWorks),
        ("Airport Ops", .aviation),
        ("School District Buses", .schools),
        ("Metro Transit Dispatch", .transit),
        ("County Jail", .corrections),
        ("Water Department", .utilities),
        ("Mutual Aid 1", .interop),
        ("FBI Field Office", .federal),
    ]

    @Test(arguments: TalkgroupCategoryTests.nameCases)
    func namesAreClassified(name: String, expected: TalkgroupCategory) {
        #expect(talkgroup(name).category == expected)
    }

    @Test func wordsInsideOtherWordsDoNotMatch() {
        // "ems" inside "Systems", "law" inside "Lawton", "dot" inside "Dotson", "gas" inside "Vegas", "tac" inside "Stacey".
        #expect(talkgroup("Systems Admin").category == .other)
        #expect(talkgroup("Lawton Municipal").category == .other)
        #expect(talkgroup("Dotson Ranch").category == .other)
        #expect(talkgroup("Las Vegas Valley").category == .other)
        #expect(talkgroup("Stacey Ln").category == .other)
    }

    @Test func aStemMatchesTheWordsThatStartWithIt() {
        #expect(talkgroup("Policing Unit").category == .law)
        #expect(talkgroup("Impolite Callers").category == .other)
    }

    @Test func theServiceTagBeatsTheName() {
        // The name says "Fire" but the source's tag says which service actually uses the talkgroup.
        #expect(talkgroup("Fire Ground", tag: "Law Dispatch").category == .law)
        #expect(talkgroup("Ops 4", group: "Sheriff").category == .law)
        #expect(talkgroup("Ops 4", tag: "Some unknown tag", group: "Fire Department").category == .fire)
    }

    @Test func aTalkgroupWithNothingToGoOnIsOther() {
        #expect(talkgroup().category == .other)
        #expect(talkgroup("Ops 4").category == .other)
    }

    @Test func everyCategoryHasANameAndASymbol() {
        for category in TalkgroupCategory.allCases {
            #expect(!category.displayName.isEmpty)
            #expect(!category.symbolName.isEmpty)
        }
    }
}

// MARK: - Browsing

private let sampleSystems: [TrunkedSystem] = [
    TrunkedSystem(shortName: "sccsd", name: "Santa Clara County Sheriff", systemType: "p25", city: "San Jose", county: "Santa Clara",
                  state: "CA", callsPerHour: 40),
    TrunkedSystem(shortName: "wmata", name: "WMATA Bus", systemType: "smartnet", city: "Washington", state: "DC", callsPerHour: 10),
    TrunkedSystem(shortName: "kc", name: "Kansas City Metro", systemType: "p25", city: "Kansas City", county: "Jackson", state: "MO",
                  callsPerHour: 40),
    TrunkedSystem(shortName: "old", name: "Old Analog Net", systemType: "smartnet", city: "Fresno", state: "CA", callsPerHour: 0,
                  isActive: false),
]

struct TrunkedSystemFilterTests {
    @Test func noFilterKeepsEverythingMostActiveFirst() {
        let list = TrunkedSystemFilter().apply(to: sampleSystems)
        #expect(list.map(\.shortName) == ["kc", "sccsd", "wmata", "old"], "equal activity is broken by name")
    }

    @Test func searchMatchesEveryWordAnywhereInTheSystem() {
        func names(_ search: String) -> [String] { TrunkedSystemFilter(search: search).apply(to: sampleSystems).map(\.shortName) }
        #expect(names("santa clara") == ["sccsd"])
        #expect(names("KANSAS") == ["kc"])
        #expect(names("p25 mo") == ["kc"])
        #expect(names("bus dc") == ["wmata"])
        #expect(names("zzz").isEmpty)
        #expect(names("   ").count == 4)
    }

    @Test func statesTypesAndActivityNarrowTheList() {
        #expect(TrunkedSystemFilter(states: ["CA"]).apply(to: sampleSystems).map(\.shortName) == ["sccsd", "old"])
        #expect(TrunkedSystemFilter(types: ["smartnet"]).apply(to: sampleSystems).map(\.shortName) == ["wmata", "old"])
        #expect(TrunkedSystemFilter(states: ["CA"], activeOnly: true).apply(to: sampleSystems).map(\.shortName) == ["sccsd"])
        #expect(TrunkedSystemFilter(states: ["ca"]).apply(to: sampleSystems).count == 2, "state codes are compared case-blind")
    }

    @Test func ordersAreNameAndState() {
        #expect(TrunkedSystemFilter(order: .name).apply(to: sampleSystems).map(\.shortName) == ["kc", "old", "sccsd", "wmata"])
        #expect(TrunkedSystemFilter(order: .location).apply(to: sampleSystems).map(\.shortName) == ["old", "sccsd", "wmata", "kc"])
    }

    @Test func thePickersListWhatIsPresent() {
        #expect(TrunkedSystemFilter.states(in: sampleSystems) == ["CA", "DC", "MO"])
        #expect(TrunkedSystemFilter.types(in: sampleSystems) == ["p25", "smartnet"])
    }
}

struct TalkgroupBrowsingTests {
    private let talkgroups: [TrunkedTalkgroup] = [
        TrunkedTalkgroup(systemShortName: "s", code: 300, alphaTag: "PW Yard", descriptionText: "Public Works Yard"),
        TrunkedTalkgroup(systemShortName: "s", code: 20, alphaTag: "FD Disp", descriptionText: "Fire Dispatch", tag: "Fire Dispatch"),
        TrunkedTalkgroup(systemShortName: "s", code: 10, alphaTag: "SO Disp", descriptionText: "Sheriff Dispatch", tag: "Law Dispatch"),
        TrunkedTalkgroup(systemShortName: "s", code: 5, alphaTag: "SO Tac", descriptionText: "Sheriff Tactical", tag: "Law Tac"),
        TrunkedTalkgroup(systemShortName: "s", code: 999, alphaTag: "Misc", descriptionText: "Unlabelled"),
    ]

    @Test func groupsFollowTheOrderOfTheCategoriesAndSortByNumber() {
        let groups = TalkgroupBrowsing.groups(talkgroups)
        #expect(groups.map(\.category) == [.law, .fire, .publicWorks, .other])
        #expect(groups[0].talkgroups.map(\.code) == [5, 10])
        #expect(groups.flatMap(\.talkgroups).count == 5)
    }

    @Test func searchAndCategoryNarrowTheGroups() {
        #expect(TalkgroupBrowsing.groups(talkgroups, search: "disp").flatMap(\.talkgroups).map(\.code).sorted() == [10, 20])
        #expect(TalkgroupBrowsing.groups(talkgroups, search: "999").flatMap(\.talkgroups).map(\.code) == [999], "the number is searchable")
        #expect(TalkgroupBrowsing.groups(talkgroups, category: .fire).flatMap(\.talkgroups).map(\.code) == [20])
        #expect(TalkgroupBrowsing.groups(talkgroups, search: "disp", category: .law).flatMap(\.talkgroups).map(\.code) == [10])
        #expect(TalkgroupBrowsing.groups(talkgroups, search: "nothing").isEmpty)
    }

    @Test func countsGroupByCategory() {
        let counts = TalkgroupBrowsing.counts(talkgroups)
        #expect(counts[.law] == 2 && counts[.fire] == 1 && counts[.publicWorks] == 1 && counts[.other] == 1)
        #expect(counts[.ems] == nil)
    }

    @Test func aTalkgroupBecomesACodeplugChannelWithoutAFrequency() {
        let system = sampleSystems[0]
        let channel = CodeplugChannel.talkgroup(talkgroups[2], on: system)
        #expect(channel.name == "SO Disp")
        #expect(channel.frequencyHz == 0)
        #expect(channel.talkgroupID == 10)
        #expect(channel.mode == .p25)
        #expect(channel.sourceCallSign == "sccsd")
        #expect(channel.notes == "Santa Clara County Sheriff: Sheriff Dispatch")

        let dmr = CodeplugChannel.talkgroup(talkgroups[0], on: TrunkedSystem(shortName: "d", name: "D", systemType: "dmr"))
        #expect(dmr.mode == .dmr)
    }

    @Test func theChannelIsOnlyValidOnARadioThatFollowsTrunkedSystems() {
        let channel = CodeplugChannel.talkgroup(talkgroups[2], on: sampleSystems[0])
        let onBaofeng = CodeplugValidator.validate(Codeplug(name: "T", target: .baofengUV5R, channels: [channel]))
        #expect(onBaofeng.contains { $0.code == .noFrequency && $0.severity == .error })

        let onUniden = CodeplugValidator.validate(Codeplug(name: "T", target: .unidenSDS100, channels: [channel]))
        #expect(onUniden.contains { $0.code == .talkgroupOnly && $0.severity == .info })
        #expect(!onUniden.contains { $0.severity == .error })
    }

    @Test func addingTalkgroupsTwiceDoesNotDuplicateThem() {
        var plan = Codeplug(name: "T", target: .unidenSDS100)
        let system = sampleSystems[0]
        let added = plan.addTalkgroups([talkgroups[2], talkgroups[3], talkgroups[2]], on: system)
        #expect(added == 2, "the same talkgroup twice in one call counts once")
        #expect(plan.channels.map(\.talkgroupID) == [5, 10], "they go in numeric order")

        let again = plan.addTalkgroups(talkgroups, on: system)
        #expect(again == 3, "only the talkgroups not already there are added")
        #expect(plan.channels.count == 5)

        let other = plan.addTalkgroups([talkgroups[2]], on: sampleSystems[2])
        #expect(other == 1, "the same number on a different system is a different talkgroup")
    }
}

import Testing
import Foundation
@testable import SignalHiveCore

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

/// A scripted network: what the next request answers, and how many requests were made.
actor FakeFeed {
    enum Answer {
        case body(Data, status: Int)
        case failure(Error)
    }
    private(set) var requests: [URLRequest] = []
    var answer: Answer

    init(_ answer: Answer) { self.answer = answer }

    func set(_ answer: Answer) { self.answer = answer }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        switch answer {
        case let .failure(error):
            throw error
        case let .body(data, status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        }
    }

    func fetch() -> ElementStore.Fetch {
        { request in try await self.respond(request) }
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("signalhive-tests-\(UUID().uuidString)")
}

private let issLine1 = "1 25544U 98067A   25273.56282970  .00013982  00000+0  25353-3 0  9991"
private let issLine2 = "2 25544  51.6311 178.9253 0004254  36.7694 323.3591 15.50035835533354"

struct ElementStoreTests {
    private func sample() throws -> Data { try Fixtures.data("celestrak-weather-sample.json") }
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeStore(_ feed: FakeFeed, _ clock: TestClock, directory: URL) async -> ElementStore {
        ElementStore(directory: directory, fetch: await feed.fetch(), now: { clock.now })
    }

    @Test func firstLoadFetchesAndCaches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.body(try sample(), status: 200))
        let clock = TestClock(start)
        let store = await makeStore(feed, clock, directory: directory)

        let load = await store.elements(group: "weather")
        #expect(load.source == .network)
        #expect(load.elements.count == 3)
        #expect(load.fetchedAt == start)
        #expect(load.rejectedRows == 0)
        #expect(await feed.requests.count == 1)
        let request = try #require(await feed.requests.first)
        #expect(request.url == ElementStore.url(forGroup: "weather"))
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("SignalHive") == true)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test func secondLoadWithin2HoursNeverTouchesTheNetwork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.body(try sample(), status: 200))
        let clock = TestClock(start)
        let store = await makeStore(feed, clock, directory: directory)
        _ = await store.elements(group: "weather")

        clock.advance(3600)
        for force in [false, true] {
            let load = await store.elements(group: "weather", forceRefresh: force)
            #expect(load.source == .cacheTooSoonToRefetch, "forceRefresh \(force)")
            #expect(load.elements.count == 3)
            #expect(load.fetchedAt == start)
        }
        clock.advance(3599) // 7199 s after the fetch
        #expect(await store.elements(group: "weather", forceRefresh: true).source == .cacheTooSoonToRefetch)
        #expect(await feed.requests.count == 1)
    }

    @Test func loadAfter2HoursRefetches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.body(try sample(), status: 200))
        let clock = TestClock(start)
        let store = await makeStore(feed, clock, directory: directory)
        _ = await store.elements(group: "weather")

        clock.advance(7200)
        let load = await store.elements(group: "weather")
        #expect(load.source == .network)
        #expect(load.fetchedAt == clock.now)
        #expect(await feed.requests.count == 2)
    }

    @Test func groupsAreCachedSeparately() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.body(try sample(), status: 200))
        let store = await makeStore(feed, TestClock(start), directory: directory)
        _ = await store.elements(group: "weather")
        let other = await store.elements(group: "stations")
        #expect(other.source == .network)
        #expect(await feed.requests.count == 2)
    }

    @Test func offlineFirstLaunchReturnsNoneWithAReadableReason() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.failure(URLError(.notConnectedToInternet)))
        let store = await makeStore(feed, TestClock(start), directory: directory)

        let load = await store.elements(group: "weather")
        #expect(load.elements.isEmpty)
        guard case let .none(reason) = load.source else {
            Issue.record("expected .none, got \(load.source)")
            return
        }
        #expect(reason.count > 10, "reason: \(reason)")
        #expect(reason.lowercased().contains("internet") || reason.lowercased().contains("offline") || reason.lowercased().contains("network"))
    }

    @Test(arguments: [429, 500, 503])
    func httpFailureFallsBackToCache(status: Int) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.body(try sample(), status: 200))
        let clock = TestClock(start)
        let store = await makeStore(feed, clock, directory: directory)
        _ = await store.elements(group: "weather")

        clock.advance(3 * 3600)
        await feed.set(.body(Data("Too Many Requests".utf8), status: status))
        let load = await store.elements(group: "weather")
        guard case let .cacheAfterFailure(reason) = load.source else {
            Issue.record("expected .cacheAfterFailure, got \(load.source)")
            return
        }
        #expect(reason.contains("\(status)"), "reason: \(reason)")
        #expect(load.elements.count == 3)
        #expect(load.fetchedAt == start)
    }

    @Test func httpFailureWithNoCacheIsNoneWithTheStatus() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.body(Data("oops".utf8), status: 500))
        let store = await makeStore(feed, TestClock(start), directory: directory)
        let load = await store.elements(group: "weather")
        guard case let .none(reason) = load.source else {
            Issue.record("expected .none, got \(load.source)")
            return
        }
        #expect(reason.contains("500"))
        #expect(load.elements.isEmpty)
    }

    @Test func malformedBodyKeepsTheOldCacheAndCountsRejects() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.body(try sample(), status: 200))
        let clock = TestClock(start)
        let store = await makeStore(feed, clock, directory: directory)
        _ = await store.elements(group: "weather")

        // A web page, a plain-text refusal, an empty list, and a list of nothing but bad rows: none may replace the cache.
        let bodies = ["<html>maintenance</html>", "No GP data found", "[]", "[{\"OBJECT_NAME\": \"X\"}]"]
        for body in bodies {
            clock.advance(3 * 3600)
            await feed.set(.body(Data(body.utf8), status: 200))
            let load = await store.elements(group: "weather")
            guard case .cacheAfterFailure = load.source else {
                Issue.record("body \(body): expected .cacheAfterFailure, got \(load.source)")
                continue
            }
            #expect(load.elements.count == 3, "body \(body)")
        }

        // A mostly good body replaces the cache and reports how many rows were bad.
        var rows = try #require(JSONSerialization.jsonObject(with: try sample()) as? [[String: Any]])
        rows.append(["OBJECT_NAME": "BROKEN"])
        clock.advance(3 * 3600)
        await feed.set(.body(try JSONSerialization.data(withJSONObject: rows), status: 200))
        let partial = await store.elements(group: "weather")
        #expect(partial.source == .network)
        #expect(partial.elements.count == 3)
        #expect(partial.rejectedRows == 1)
    }

    @Test func cacheSurvivesAProcessRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = FakeFeed(.body(try sample(), status: 200))
        let clock = TestClock(start)
        let first = await makeStore(feed, clock, directory: directory)
        _ = await first.elements(group: "weather")

        // A new store on the same directory, as after relaunching the app, with the network unreachable.
        let offline = FakeFeed(.failure(URLError(.notConnectedToInternet)))
        clock.advance(1800)
        let second = await makeStore(offline, clock, directory: directory)
        let soon = await second.elements(group: "weather")
        #expect(soon.source == .cacheTooSoonToRefetch)
        #expect(soon.elements.count == 3)
        #expect(await offline.requests.isEmpty)

        clock.advance(3 * 3600)
        let later = await second.elements(group: "weather")
        guard case .cacheAfterFailure = later.source else {
            Issue.record("expected .cacheAfterFailure, got \(later.source)")
            return
        }
        #expect(later.elements.count == 3)
    }

    @Test func importAddsElementsFromTLEAndOMMText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await makeStore(FakeFeed(.failure(URLError(.cancelled))), TestClock(start), directory: directory)

        #expect(try await store.importElements("ISS (ZARYA)\n\(issLine1)\n\(issLine2)\n", named: "iss.tle") == 1)
        let omm = String(decoding: try sample(), as: UTF8.self)
        #expect(try await store.importElements(omm, named: "weather.json") == 3)
        let csv = try Fixtures.text("celestrak-sample.csv")
        #expect(try await store.importElements(csv, named: "weather.csv") == 3)

        let imported = await store.importedElements()
        #expect(imported.count == 4) // ISS plus three weather sets, the repeated ones merged by catalog number
        #expect(imported.contains { $0.noradID == 25544 && $0.name == "ISS (ZARYA)" })

        // The imports survive a restart.
        let again = await makeStore(FakeFeed(.failure(URLError(.cancelled))), TestClock(start), directory: directory)
        #expect(await again.importedElements().count == 4)
    }

    @Test func importOfGarbageThrowsAndNothingIsStored() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await makeStore(FakeFeed(.failure(URLError(.cancelled))), TestClock(start), directory: directory)
        await #expect(throws: ElementParser.ParseError.self) { try await store.importElements("this is not an element set", named: "x.txt") }
        await #expect(throws: ElementParser.ParseError.self) { try await store.importElements("<html></html>", named: "x.json") }
        #expect(await store.importedElements().isEmpty)
    }

    @Test func urlUsesJSONFormatAndTheGroup() {
        #expect(ElementStore.url(forGroup: "weather").absoluteString == "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=json")
        #expect(ElementStore.url(forGroup: "amateur").absoluteString == "https://celestrak.org/NORAD/elements/gp.php?GROUP=amateur&FORMAT=json")
    }

    @Test func ageBoundaries() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        /// The kind of confidence and its day count, so a Date's rounding (about 1e-7 s) cannot fail an equality.
        func kind(daysOld: Double) -> (name: String, days: Double?) {
            switch ElementAge.confidence(epoch: now.addingTimeInterval(-daysOld * 86_400), now: now) {
            case .good: return ("good", nil)
            case let .aging(days): return ("aging", days)
            case let .stale(days): return ("stale", days)
            case let .unusable(days): return ("unusable", days)
            case .fromTheFuture: return ("future", nil)
            }
        }
        func expect(_ daysOld: Double, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let result = kind(daysOld: daysOld)
            #expect(result.name == name, "\(daysOld) days old is \(result.name)", sourceLocation: sourceLocation)
            if let days = result.days {
                #expect(abs(days - daysOld) < 1e-6, "reported \(days) days for \(daysOld)", sourceLocation: sourceLocation)
            }
        }
        expect(0, "good")
        expect(2.9, "good")
        expect(3.0, "aging")
        expect(6.99, "aging")
        expect(7.0, "stale")
        expect(29.9, "stale")
        expect(30.0, "unusable")
        expect(400, "unusable")
        // An epoch up to an hour ahead is clock skew; further ahead is wrong data.
        #expect(ElementAge.confidence(epoch: now.addingTimeInterval(1800), now: now) == .good)
        #expect(ElementAge.confidence(epoch: now.addingTimeInterval(2 * 3600), now: now) == .fromTheFuture)
    }
}

import Testing
import Foundation
@testable import SignalHiveCore

/// A scripted SatNOGS: one body per URL path, an optional failure, and a request log.
actor RoutedFeed {
    private(set) var requests: [URLRequest] = []
    var routes: [String: Data]
    var status = 200
    var failure: Error?

    init(routes: [String: Data]) { self.routes = routes }

    func set(status: Int) { self.status = status }
    func set(failure: Error?) { self.failure = failure }
    func set(route: String, body: Data) { routes[route] = body }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if let failure { throw failure }
        // URL.path has dropped a trailing slash on some Foundation versions, so compare without it.
        let key = (request.url?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let body = routes.first { $0.key.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == key }?.value ?? Data("[]".utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func fetch() -> ElementStore.Fetch { { request in try await self.respond(request) } }
}

private func satnogsFeed() throws -> RoutedFeed {
    RoutedFeed(routes: ["/api/transmitters/": try Fixtures.data("satnogs-transmitters-sample.json"),
                        "/api/satellites/": try Fixtures.data("satnogs-satellites-sample.json")])
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("signalhive-tests-\(UUID().uuidString)")
}

struct TransmitterStoreTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func parsesSavedLiveResponses() throws {
        let transmitters = try TransmitterStore.parseTransmitters(try Fixtures.data("satnogs-transmitters-sample.json"))
        #expect(transmitters.transmitters.count > 80)
        let lrpt = try #require(transmitters.transmitters.first { $0.noradID == 59051 && $0.downlinkHz == 137_912_500 })
        #expect(lrpt.kind == .lrpt)
        #expect(lrpt.mode == "LRPT")
        #expect(lrpt.isActive)
        #expect(lrpt.summary.contains("LRPT"))
        #expect(lrpt.verifiedOnAir == nil)

        let satellites = try TransmitterStore.parseSatellites(try Fixtures.data("satnogs-satellites-sample.json"))
        #expect(satellites.statuses[59051] == .alive)
        #expect(satellites.statuses[25544] == .alive)
        #expect(satellites.statuses[2012] == .reentered)
        #expect(satellites.statuses[99681] == .future)
        #expect(satellites.rejected == 1) // "Satellite with data but without NORAD ID"
    }

    @Test func nullFrequencyAndUnknownModeAreTolerated() throws {
        let parsed = try TransmitterStore.parseTransmitters(try Fixtures.data("satnogs-transmitters-sample.json"))
        // Three real rows have downlink_low null (a transmitter with no downlink): skipped and counted.
        #expect(parsed.rejected == 3)
        // A real "UNKNOWN" mode and a real null mode both read as .unknown without throwing.
        let unknownMode = try #require(parsed.transmitters.first { $0.id == "NkichMcsQAbKQNmc9coWdS" })
        #expect(unknownMode.kind == .unknown)
        let noMode = try #require(parsed.transmitters.first { $0.id == "iQRkZ4BeNeTphSGEwtBztm" })
        #expect(noMode.mode == nil && noMode.kind == .unknown)

        // A mode nobody has heard of is a signal we cannot name, not an error.
        let invented = Data(#"[{"uuid": "x1", "norad_cat_id": 1, "downlink_low": 145800000, "mode": "WARPDRIVE", "status": "active", "alive": true, "description": "?"}]"#.utf8)
        let result = try TransmitterStore.parseTransmitters(invented)
        #expect(result.transmitters.first?.kind == .other)
        #expect(result.rejected == 0)
    }

    @Test func garbageRowsAreCountedNotFatal() throws {
        let body = Data(#"[{"uuid": "ok", "norad_cat_id": 5, "downlink_low": 137100000, "mode": "LRPT", "status": "active"}, "text", 7, {"norad_cat_id": 3}, {"uuid": "nonorad", "downlink_low": 1}]"#.utf8)
        let result = try TransmitterStore.parseTransmitters(body)
        #expect(result.transmitters.map(\.id) == ["ok"])
        #expect(result.rejected == 4)
        #expect(throws: ElementParser.ParseError.self) { try TransmitterStore.parseTransmitters(Data("<html></html>".utf8)) }
        #expect(throws: ElementParser.ParseError.self) { try TransmitterStore.parseTransmitters(Data(#"{"detail": "throttled"}"#.utf8)) }
    }

    @Test func inactiveTransmittersAreMarkedInactive() throws {
        let parsed = try TransmitterStore.parseTransmitters(try Fixtures.data("satnogs-transmitters-sample.json"))
        let sstv = try #require(parsed.transmitters.first { $0.noradID == 25544 && $0.mode == "SSTV" })
        #expect(!sstv.isActive)
        let apt = parsed.transmitters.filter { $0.noradID == 25338 && $0.mode == "APT" }
        #expect(!apt.isEmpty && apt.allSatisfy { !$0.isActive }, "NOAA 15's APT is off the air and must not read as active")
    }

    @Test func respectsTheOneDayRefetchInterval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = try satnogsFeed()
        let clock = TestClock(start)
        let store = TransmitterStore(directory: directory, fetch: await feed.fetch(), now: { clock.now })

        let first = await store.load()
        #expect(first.source == .network)
        #expect(await feed.requests.count == 2)
        #expect(first.satellites[59051] == .alive)

        clock.advance(23 * 3600)
        let soon = await store.load(forceRefresh: true)
        #expect(soon.source == .cacheTooSoonToRefetch)
        #expect(await feed.requests.count == 2)
        #expect(soon.transmitters.count == first.transmitters.count)

        clock.advance(3600)
        #expect(await store.load().source == .network)
        #expect(await feed.requests.count == 4)
    }

    @Test func offlineFirstLaunchHasAReadableReason() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = try satnogsFeed()
        await feed.set(failure: URLError(.notConnectedToInternet))
        let store = TransmitterStore(directory: directory, fetch: await feed.fetch(), now: { Date(timeIntervalSince1970: 1_790_000_000) })
        let load = await store.load()
        #expect(load.transmitters.isEmpty && load.satellites.isEmpty)
        guard case let .none(reason) = load.source else {
            Issue.record("expected .none, got \(load.source)")
            return
        }
        #expect(reason.lowercased().contains("internet"), "reason: \(reason)")
    }

    @Test func failureOrABadBodyKeepsTheSavedCopy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = try satnogsFeed()
        let clock = TestClock(start)
        let store = TransmitterStore(directory: directory, fetch: await feed.fetch(), now: { clock.now })
        let first = await store.load()

        clock.advance(25 * 3600)
        await feed.set(status: 503)
        let failed = await store.load()
        guard case let .cacheAfterFailure(reason) = failed.source else {
            Issue.record("expected .cacheAfterFailure, got \(failed.source)")
            return
        }
        #expect(reason.contains("503"))
        #expect(failed.transmitters.count == first.transmitters.count)

        await feed.set(status: 200)
        await feed.set(route: "/api/transmitters/", body: Data("<html>down for maintenance</html>".utf8))
        let malformed = await store.load()
        guard case .cacheAfterFailure = malformed.source else {
            Issue.record("expected .cacheAfterFailure, got \(malformed.source)")
            return
        }
        #expect(malformed.satellites[59051] == .alive)
    }

    @Test func cacheSurvivesARestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(start)
        let first = TransmitterStore(directory: directory, fetch: await (try satnogsFeed()).fetch(), now: { clock.now })
        _ = await first.load()
        let offline = RoutedFeed(routes: [:])
        await offline.set(failure: URLError(.notConnectedToInternet))
        clock.advance(3600)
        let second = TransmitterStore(directory: directory, fetch: await offline.fetch(), now: { clock.now })
        let load = await second.load()
        #expect(load.source == .cacheTooSoonToRefetch)
        #expect(load.satellites[59051] == .alive)
        #expect(await offline.requests.isEmpty)
    }

    @Test(arguments: [
        ("LRPT", nil, SignalKind.lrpt), ("lrpt", nil, .lrpt),
        ("FM", nil, .fmVoice), ("FMN", nil, .fmVoice),
        ("SSTV", nil, .sstv),
        ("AFSK", 1200.0, .aprs), ("AFSK", 9600.0, .other), ("AFSK", nil, .other),
        ("CW", nil, .cwBeacon),
        ("BPSK", 1200.0, .bpskTelemetry), ("BPSK PMT-A3", 800.0, .bpskTelemetry),
        ("GMSK", 9600.0, .other), ("FSK AX.25 G3RUH", 9600.0, .other),
        (nil, nil, .unknown), ("UNKNOWN", nil, .unknown), ("", nil, .unknown),
    ] as [(String?, Double?, SignalKind)])
    func modeMapping(mode: String?, baud: Double?, expected: SignalKind) {
        #expect(SignalKind(satnogsMode: mode, baud: baud) == expected)
    }

    @Test func noModeIsReadyYet() {
        let kinds: [SignalKind] = [.lrpt, .fmVoice, .sstv, .aprs, .cwBeacon, .bpskTelemetry, .other, .unknown]
        #expect(kinds.allSatisfy { $0.decoderStatus != .ready }, "no decoder is wired to a satellite recorder in this phase")
        #expect(SignalKind.lrpt.decoderStatus == .planned)
        #expect(SignalKind.bpskTelemetry.decoderStatus == DecoderStatus.none)
    }

    @Test func attributionNamesTheLicence() {
        #expect(TransmitterStore.attribution == "Transmitter data: SatNOGS DB (CC BY-SA 4.0), db.satnogs.org")
    }
}

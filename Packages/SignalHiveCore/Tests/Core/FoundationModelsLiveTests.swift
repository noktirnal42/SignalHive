import Testing
import Foundation
@testable import SignalHiveCore

/// Talks to the real on-device model, so it is opt-in: `SIGNALHIVE_LIVE_AI=1 swift test --filter FoundationModelsLiveTests`.
/// Private Cloud Compute has no live test on purpose: it would send the context off the Mac.
struct FoundationModelsLiveTests {
    private static let enabled = ProcessInfo.processInfo.environment["SIGNALHIVE_LIVE_AI"] == "1"

    @Test(.enabled(if: FoundationModelsLiveTests.enabled))
    func theOnDeviceModelAnswersAndStreamsWhenAvailable() async throws {
        let provider = FoundationOnDeviceProvider()
        guard case .available = await provider.availability() else {
            Issue.record("on-device model unavailable: \(await provider.availability())")
            return
        }
        let request = AIRequest.explain(SignalDescriptionContext(frequencyHz: 162_550_000, mode: .nfm, rssiDBFS: -53))
        var partials: [String] = []
        var answer: AIAnswer?
        for try await chunk in AIRouter(providers: [provider]).answer(request) {
            switch chunk {
            case let .partial(text, kind):
                #expect(kind == .foundationOnDevice)
                partials.append(text)
            case let .done(final): answer = final
            }
        }
        let final = try #require(answer)
        print("LIVE provider=\(final.provider) latency=\(final.latency)s confidence=\(final.confidence)")
        print("LIVE summary=\(final.summary)")
        print("LIVE next=\(final.recommendation ?? "nil")")
        print("LIVE notes=\(final.notes) partials=\(partials.count)")

        #expect(final.provider == .foundationOnDevice, "notes: \(final.notes)")
        #expect(!final.summary.isEmpty)
        #expect(partials.count > 1, "the answer should stream")
        #expect(partials.last == final.summary, "partials carry the text so far, so the last one is the whole summary")
    }

    @Test(.enabled(if: FoundationModelsLiveTests.enabled))
    func theOnDeviceModelBriefsAnAirPictureWithoutInventingTraffic() async throws {
        let provider = FoundationOnDeviceProvider()
        guard case .available = await provider.availability() else {
            Issue.record("on-device model unavailable")
            return
        }
        let t = Date(timeIntervalSinceReferenceDate: 5_000_000)
        var picture = AviationPicture(receiver: GeoCoordinate(latitude: 40, longitude: -100))
        picture.apply(AircraftReport(address: 0xA1, source: .modeS, time: t, callsign: "UAL100", altitudeFeet: 37_000,
                                     coordinate: GeoCoordinate(latitude: 41, longitude: -100), groundSpeedKnots: 480, onGround: false))
        picture.apply(AircraftReport(address: 0xB1, source: .modeS, time: t, callsign: "N911", squawk: "7700", altitudeFeet: 4_000))
        picture.apply(.message(.fisbReport("METAR KJFK 011651Z 18016G26KT 1 1/2SM -RA BR BKN008 OVC015 12/11 A2985", at: t)))
        let briefing = AviationBriefing.make(from: picture, now: t)

        var final: AIAnswer?
        for try await chunk in AIRouter(providers: [provider]).answer(.brief(briefing)) {
            if case let .done(answer) = chunk { final = answer }
        }
        let answer = try #require(final)
        print("LIVE briefing provider=\(answer.provider) latency=\(answer.latency)s confidence=\(answer.confidence)")
        print("LIVE briefing summary=\(answer.summary)")
        print("LIVE briefing next=\(answer.recommendation ?? "nil") notes=\(answer.notes)")

        #expect(answer.provider == .foundationOnDevice, "notes: \(answer.notes)")
        #expect(!answer.summary.isEmpty)
        #expect(answer.facts.first?.contains("EMERGENCY: N911") == true)
    }
}

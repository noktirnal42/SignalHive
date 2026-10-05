import Testing
import Foundation
@testable import SignalHiveCore

/// Records what a fake provider was asked, from inside the stream so the record exists before the stream finishes.
private actor Recorder {
    private(set) var requests: [AIRequest] = []
    func record(_ request: AIRequest) { requests.append(request) }
}

private struct FakeFailure: Error, LocalizedError {
    var errorDescription: String? { "the model crashed" }
}

private struct FakeProvider: LanguageModelProvider {
    var kind: AIProviderKind
    var state: ProviderAvailability = .available
    var chunks: [AIChunk] = []
    var failure: (any Error)?
    var delay: Duration?
    var recorder: Recorder?

    func availability() async -> ProviderAvailability { state }

    func respond(to request: AIRequest) -> AsyncThrowingStream<AIChunk, Error> {
        let script = self, kind = kind
        return AsyncThrowingStream { continuation in
            Task {
                await script.recorder?.record(request)
                if let delay = script.delay { try? await Task.sleep(for: delay) }
                for chunk in script.chunks { continuation.yield(chunk) }
                if let failure = script.failure {
                    continuation.finish(throwing: failure)
                } else {
                    _ = kind
                    continuation.finish()
                }
            }
        }
    }

    static func answering(_ kind: AIProviderKind, summary: String = "model text", recommendation: String? = "model next",
                          recorder: Recorder? = nil, state: ProviderAvailability = .available) -> FakeProvider {
        FakeProvider(kind: kind, state: state,
                     chunks: [.done(AIAnswer(provider: kind, summary: summary, recommendation: recommendation, confidence: "medium"))],
                     recorder: recorder)
    }
}

private func collect(_ stream: AsyncThrowingStream<AIChunk, Error>) async throws -> (partials: [AIChunk], answer: AIAnswer) {
    var partials: [AIChunk] = []
    var answer: AIAnswer?
    for try await chunk in stream {
        switch chunk {
        case .partial: partials.append(chunk)
        case let .done(final): answer = final
        }
    }
    return (partials, try #require(answer, "the router must always finish with an answer"))
}

struct AIRouterTests {
    private let weather = AIRequest.explain(SignalDescriptionContext(frequencyHz: 162_550_000, mode: .nfm, rssiDBFS: -53,
                                                                     licensee: "NOAA Weather Radio"))

    private func router(_ providers: [FakeProvider]) -> AIRouter { AIRouter(providers: providers) }

    // MARK: Rules are always there

    @Test func rulesAnswerWhenNoModelIsRegistered() async throws {
        let (_, answer) = try await collect(router([]).answer(weather))

        #expect(answer.provider == .rulesEngine)
        #expect(answer.summary.contains("NOAA Weather Radio channels"))
        #expect(answer.confidence.hasPrefix("rules"))
        #expect(answer.facts.isEmpty, "rules are the facts; they are not repeated under their own answer")
        #expect(answer.recommendation?.isEmpty == false)
    }

    @Test func rulesOnlyNeverCallsAModel() async throws {
        let recorder = Recorder()
        let onDevice = FakeProvider.answering(.foundationOnDevice, recorder: recorder)
        var request = weather
        request.preferred = .rulesEngine

        let (_, answer) = try await collect(router([onDevice]).answer(request))

        #expect(answer.provider == .rulesEngine)
        #expect(await recorder.requests.isEmpty)
    }

    // MARK: Automatic order

    @Test func automaticRoutingUsesTheOnDeviceModelAndKeepsTheRulesFacts() async throws {
        let (_, answer) = try await collect(router([.answering(.foundationOnDevice)]).answer(weather))

        #expect(answer.provider == .foundationOnDevice)
        #expect(answer.summary == "model text")
        #expect(answer.recommendation == "model next")
        #expect(answer.facts.count == 1)
        #expect(answer.facts.first?.contains("NOAA Weather Radio channels") == true)
    }

    @Test func theModelIsGivenTheRulesFactsToStayGroundedIn() async throws {
        let recorder = Recorder()
        _ = try await collect(router([.answering(.foundationOnDevice, recorder: recorder)]).answer(weather))

        let seen = try #require(await recorder.requests.first)
        #expect(seen.grounding.count == 1)
        #expect(seen.grounding.first?.contains("NOAA Weather Radio channels") == true)
    }

    @Test func theAnswerListsTheInputsItUsed() async throws {
        let (_, answer) = try await collect(router([.answering(.foundationOnDevice)]).answer(weather))

        #expect(answer.inputs.contains("Frequency 162.55000 MHz"))
        #expect(answer.inputs.contains("Mode NFM"))
        #expect(answer.inputs.contains("Level -53 dBFS"))
        #expect(answer.inputs.contains("Licensee NOAA Weather Radio"))
    }

    @Test func aTalkgroupHasNoFrequencyAmongItsInputs() {
        // OpenMHz talkgroups carry no frequency; the caller passes 0, which must not reach the model as a fact.
        let talkgroup = AIContext(signal: SignalDescriptionContext(frequencyHz: 0, trunkedSystemName: "Metro P25", talkgroupCode: 1204))

        #expect(talkgroup.inputs.contains("Talkgroup 1204"))
        #expect(talkgroup.inputs.contains("Trunked system Metro P25"))
        #expect(!talkgroup.inputs.contains { $0.hasPrefix("Frequency") })
    }

    @Test func theRouterNamesTheProviderThatReallyAnswered() async throws {
        let mislabeled = FakeProvider(kind: .foundationOnDevice,
                                      chunks: [.done(AIAnswer(provider: .rulesEngine, summary: "x", recommendation: "y", confidence: "high"))])
        let (_, answer) = try await collect(router([mislabeled]).answer(weather))
        #expect(answer.provider == .foundationOnDevice)
    }

    @Test func aMissingRecommendationComesFromTheRulesAndSaysSo() async throws {
        let (_, answer) = try await collect(router([.answering(.foundationOnDevice, recommendation: nil)]).answer(weather))

        #expect(answer.recommendation?.isEmpty == false)
        #expect(answer.notes.contains { $0.contains("next step") && $0.contains("SignalHive Rules") })
    }

    // MARK: Fallbacks say why

    @Test func anUnavailableModelFallsBackToRulesAndSaysWhy() async throws {
        let off = FakeProvider.answering(.foundationOnDevice, state: .unavailable("Apple Intelligence is turned off"))
        let (_, answer) = try await collect(router([off]).answer(weather))

        #expect(answer.provider == .rulesEngine)
        #expect(answer.notes.contains { $0.contains("Apple Foundation Model") && $0.contains("Apple Intelligence is turned off") })
    }

    @Test func aFailingModelFallsBackToRulesAndSaysWhy() async throws {
        let broken = FakeProvider(kind: .foundationOnDevice, failure: FakeFailure())
        let (_, answer) = try await collect(router([broken]).answer(weather))

        #expect(answer.provider == .rulesEngine)
        #expect(answer.notes.contains { $0.contains("the model crashed") })
    }

    @Test func aFailureAfterPartialTextStillEndsWithAnAnswer() async throws {
        let halfway = FakeProvider(kind: .foundationOnDevice, chunks: [.partial("The signal is", .foundationOnDevice)],
                                   failure: FakeFailure())
        let (partials, answer) = try await collect(router([halfway]).answer(weather))

        #expect(!partials.isEmpty)
        #expect(answer.provider == .rulesEngine)
    }

    // MARK: Private Cloud Compute is the user's choice

    @Test func privateCloudIsNeverUsedAutomatically() async throws {
        let recorder = Recorder()
        let off = FakeProvider.answering(.foundationOnDevice, state: .unavailable("off"))
        let cloud = FakeProvider.answering(.foundationPrivateCloud, recorder: recorder)

        let (_, answer) = try await collect(router([off, cloud]).answer(weather))

        #expect(answer.provider == .rulesEngine)
        #expect(await recorder.requests.isEmpty, "context left the Mac without the user asking for it")
    }

    @Test func privateCloudAnswersWhenTheUserPicksIt() async throws {
        var request = weather
        request.preferred = .foundationPrivateCloud
        let (_, answer) = try await collect(router([.answering(.foundationOnDevice), .answering(.foundationPrivateCloud, summary: "cloud text")])
            .answer(request))

        #expect(answer.provider == .foundationPrivateCloud)
        #expect(answer.summary == "cloud text")
    }

    @Test func anUnavailablePreferredModelFallsBackToTheAutomaticOrder() async throws {
        var request = weather
        request.preferred = .foundationPrivateCloud
        let cloudOff = FakeProvider.answering(.foundationPrivateCloud, state: .unavailable("quota reached"))
        let (_, answer) = try await collect(router([.answering(.foundationOnDevice), cloudOff]).answer(request))

        #expect(answer.provider == .foundationOnDevice)
        #expect(answer.notes.contains { $0.contains("Private Cloud Compute") && $0.contains("quota reached") })
    }

    // MARK: Streaming and timing

    @Test func partialTextIsStreamedBeforeTheAnswerAndLabelledWithItsProvider() async throws {
        let streaming = FakeProvider(kind: .foundationOnDevice, chunks: [
            .partial("Hel", .foundationOnDevice),
            .partial("Hello", .foundationOnDevice),
            .done(AIAnswer(provider: .foundationOnDevice, summary: "Hello", recommendation: "go", confidence: "high")),
        ])
        let (partials, answer) = try await collect(router([streaming]).answer(weather))

        #expect(partials == [.partial("Hel", .foundationOnDevice), .partial("Hello", .foundationOnDevice)])
        #expect(answer.summary == "Hello")
    }

    @Test func latencyIsMeasuredByTheRouter() async throws {
        let slow = FakeProvider(kind: .foundationOnDevice,
                                chunks: [.done(AIAnswer(provider: .foundationOnDevice, summary: "x", recommendation: "y", confidence: "high"))],
                                delay: .milliseconds(60))
        let (_, answer) = try await collect(router([slow]).answer(weather))

        #expect(answer.latency >= 0.05)
    }

    // MARK: Prompt and parsing (pure)

    @Test func thePromptCarriesTheContextTheFactsAndTheGuardrails() {
        var request = weather
        request.grounding = ["162.55000 MHz falls in the NOAA Weather Radio channels."]
        let prompt = AIPrompt.explainSignal(request)

        #expect(prompt.contains("162.55000 MHz"))
        #expect(prompt.contains("Mode NFM"))
        #expect(prompt.contains("NOAA Weather Radio channels"))
        #expect(prompt.contains("SUMMARY:") && prompt.contains("NEXT:") && prompt.contains("CONFIDENCE:"))
        #expect(prompt.localizedCaseInsensitiveContains("never contradict"))
        #expect(!prompt.contains("Talkgroup"), "inputs that are absent are not mentioned")
    }

    @Test func labelledModelTextIsParsedIntoParts() {
        let parsed = AIResponseParser.parse("""
        SUMMARY: This is a NOAA weather channel.
        NEXT: Use NFM and save it.
        CONFIDENCE: High
        """)

        #expect(parsed.summary == "This is a NOAA weather channel.")
        #expect(parsed.recommendation == "Use NFM and save it.")
        #expect(parsed.confidence == "high")
    }

    @Test func unlabelledModelTextBecomesTheSummary() {
        let parsed = AIResponseParser.parse("  Just a plain sentence.  ")

        #expect(parsed.summary == "Just a plain sentence.")
        #expect(parsed.recommendation == nil)
        #expect(parsed.confidence == nil)
    }

    @Test func aMultilineSummaryIsKeptWhole() {
        let parsed = AIResponseParser.parse("SUMMARY: Line one.\nLine two.\nNEXT: Do it.")

        #expect(parsed.summary == "Line one.\nLine two.")
        #expect(parsed.recommendation == "Do it.")
    }

    @Test func aPartialStreamShowsOnlyTheSummaryText() {
        #expect(AIResponseParser.displayText(forPartial: "SUMMARY: The signal is") == "The signal is")
        #expect(AIResponseParser.displayText(forPartial: "The signal is") == "The signal is")
    }
}

// MARK: - Aviation briefing task

private func sampleBriefing() -> AviationBriefing {
    let t = Date(timeIntervalSinceReferenceDate: 5_000_000)
    var picture = AviationPicture(receiver: GeoCoordinate(latitude: 40, longitude: -100))
    picture.apply(AircraftReport(address: 0xA1, source: .modeS, time: t, callsign: "UAL100", altitudeFeet: 37_000,
                                 coordinate: GeoCoordinate(latitude: 41, longitude: -100), groundSpeedKnots: 480, onGround: false))
    picture.apply(.message(.fisbReport("METAR KJFK 011651Z 18016G26KT 1 1/2SM -RA BR BKN008 OVC015 12/11 A2985", at: t)))
    return AviationBriefing.make(from: picture, now: t)
}

struct AIBriefingRouterTests {
    private let briefing = sampleBriefing()

    @Test func rulesAnswerTheBriefingWithTheDigest() async throws {
        let (_, answer) = try await collect(AIRouter(providers: []).answer(.brief(briefing)))

        #expect(answer.provider == .rulesEngine)
        #expect(answer.summary.hasPrefix(briefing.headline))
        for line in briefing.lines { #expect(answer.summary.contains(line), "\(line)") }
        #expect(answer.recommendation == nil, "the digest states facts; it does not invent a next step")
        #expect(answer.confidence.hasPrefix("rules"))
    }

    @Test func theAnswerListsWhatTheBriefingCovered() async throws {
        let (_, answer) = try await collect(AIRouter(providers: []).answer(.brief(briefing)))

        #expect(answer.inputs == ["Aircraft tracked 1", "Emergencies 0", "Weather stations 1", "Hazard products 0"])
    }

    @Test func aModelIsHeldToTheDigest() async throws {
        let recorder = Recorder()
        let model = FakeProvider.answering(.foundationOnDevice, summary: "Quiet sky.", recommendation: nil, recorder: recorder)
        let (_, answer) = try await collect(AIRouter(providers: [model]).answer(.brief(briefing)))

        let seen = try #require(await recorder.requests.first)
        #expect(seen.grounding.first?.contains("1 aircraft tracked") == true)
        #expect(answer.provider == .foundationOnDevice)
        #expect(answer.facts == seen.grounding)
        #expect(answer.recommendation == nil, "no next step from the model and none from the rules, so none is shown")
        #expect(answer.notes.isEmpty)
    }

    @Test func theBriefingPromptCarriesTheDigestAndTheGuardrails() {
        var request = AIRequest.brief(briefing)
        request.grounding = briefing.lines
        let prompt = AIPrompt.briefAviation(request)

        #expect(prompt.contains("Aircraft tracked 1"))
        #expect(prompt.contains(briefing.lines[0]))
        #expect(prompt.contains("SUMMARY:") && prompt.contains("NEXT:") && prompt.contains("CONFIDENCE:"))
        #expect(prompt.localizedCaseInsensitiveContains("never contradict"))
        #expect(prompt.localizedCaseInsensitiveContains("aviation"))
    }

    @Test func aRequestWithoutItsContextFailsInsteadOfInventingOne() async {
        let noBriefing = AIRequest(task: .briefAviation, context: AIContext())
        let noSignal = AIRequest(task: .explainSignal, context: AIContext(aviation: briefing))

        for request in [noBriefing, noSignal] {
            await #expect(throws: AIError.missingContext) { _ = try await collect(AIRouter(providers: []).answer(request)) }
        }
    }
}

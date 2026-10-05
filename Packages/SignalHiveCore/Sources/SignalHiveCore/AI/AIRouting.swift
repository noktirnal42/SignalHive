import Foundation

// One way to ask the app's AI for an explanation, whatever answers. A deterministic rules answer is always available and
// grounds every model answer, so a model cannot be the only voice and its answer always says who gave it, from what
// inputs, and how long it took. Nothing goes off the Mac except through Private Cloud Compute, and only when the user
// picks it.

public enum AITask: Equatable, Sendable {
    /// What is this signal, and what should the operator do next.
    case explainSignal
    /// What is in the air and in the weather reports right now, in plain words.
    case briefAviation
}

/// Plain values the caller gathered; the AI never reaches into app state.
public struct AIContext: Equatable, Sendable {
    public var signal: SignalDescriptionContext?
    public var aviation: AviationBriefing?

    public init(signal: SignalDescriptionContext? = nil, aviation: AviationBriefing? = nil) {
        self.signal = signal
        self.aviation = aviation
    }

    /// The inputs as short labelled lines, for the prompt and for showing the operator what was used.
    public var inputs: [String] {
        var lines = signalInputs
        if let aviation {
            lines += [
                "Aircraft tracked \(aviation.traffic.tracked)",
                "Emergencies \(aviation.emergencies.count)",
                "Weather stations \(aviation.weather.stations)",
                "Hazard products \(aviation.hazards.sigmets + aviation.hazards.airmets + aviation.hazards.advisories + aviation.hazards.restrictions)",
            ]
        }
        return lines
    }

    private var signalInputs: [String] {
        guard let signal else { return [] }
        // Talkgroups have no frequency; callers pass 0, which is "none", not a frequency to report.
        var lines = signal.frequencyHz > 0 ? [String(format: "Frequency %.5f MHz", signal.frequencyHz / 1_000_000)] : []
        if let mode = signal.mode { lines.append("Mode \(mode.rawValue)") }
        if let bandwidth = signal.bandwidthHz, bandwidth > 0 { lines.append(String(format: "Bandwidth %.1f kHz", bandwidth / 1_000)) }
        if let level = signal.rssiDBFS { lines.append(String(format: "Level %.0f dBFS", level)) }
        if let licensee = signal.licensee { lines.append("Licensee \(licensee)") }
        if let callSign = signal.callSign { lines.append("Call sign \(callSign)") }
        if let service = signal.serviceName { lines.append("Service \(service)") }
        if let system = signal.trunkedSystemName { lines.append("Trunked system \(system)") }
        if let talkgroup = signal.talkgroupCode { lines.append("Talkgroup \(talkgroup)") }
        let hints = signal.modeHints.filter { $0 != .unknown }.map(\.displayName)
        if !hints.isEmpty { lines.append("Emission hints \(hints.joined(separator: ", "))") }
        if let note = signal.contextNote, !note.isEmpty { lines.append("Note \(note)") }
        return lines
    }
}

public struct AIRequest: Sendable {
    public var task: AITask
    public var context: AIContext
    /// The provider the user chose, if any. Private Cloud Compute is only ever used when it is chosen here.
    public var preferred: AIProviderKind?
    /// Facts the answer must not contradict. The router fills this from the rules answer before asking a model.
    public var grounding: [String]

    public init(task: AITask, context: AIContext, preferred: AIProviderKind? = nil, grounding: [String] = []) {
        self.task = task
        self.context = context
        self.preferred = preferred
        self.grounding = grounding
    }

    public static func explain(_ signal: SignalDescriptionContext, preferred: AIProviderKind? = nil) -> AIRequest {
        AIRequest(task: .explainSignal, context: AIContext(signal: signal), preferred: preferred)
    }

    public static func brief(_ briefing: AviationBriefing, preferred: AIProviderKind? = nil) -> AIRequest {
        AIRequest(task: .briefAviation, context: AIContext(aviation: briefing), preferred: preferred)
    }
}

public struct AIAnswer: Equatable, Sendable {
    /// Who answered. The router sets this to the provider it really used.
    public var provider: AIProviderKind
    public var summary: String
    public var recommendation: String?
    public var confidence: String
    /// The rules answer a model answer was held to. Empty for the rules answer itself.
    public var facts: [String]
    /// What the answer was built from.
    public var inputs: [String]
    /// Why a provider was skipped or failed, and anything that came from somewhere other than the answering provider.
    public var notes: [String]
    /// Seconds from the request to this answer, fallbacks included.
    public var latency: TimeInterval

    public init(provider: AIProviderKind, summary: String, recommendation: String?, confidence: String,
                facts: [String] = [], inputs: [String] = [], notes: [String] = [], latency: TimeInterval = 0) {
        self.provider = provider
        self.summary = summary
        self.recommendation = recommendation
        self.confidence = confidence
        self.facts = facts
        self.inputs = inputs
        self.notes = notes
        self.latency = latency
    }
}

public enum AIChunk: Equatable, Sendable {
    /// The summary so far, from the named provider. A partial from a different provider replaces the earlier text.
    case partial(String, AIProviderKind)
    case done(AIAnswer)
}

public enum ProviderAvailability: Equatable, Sendable {
    case available
    /// Why not, in words the operator can act on.
    case unavailable(String)
}

public enum AIError: Error, LocalizedError, Equatable {
    case missingContext
    case noAnswer

    public var errorDescription: String? {
        switch self {
        case .missingContext: return "The request has no signal context to explain."
        case .noAnswer: return "The provider finished without an answer."
        }
    }
}

public protocol LanguageModelProvider: Sendable {
    var kind: AIProviderKind { get }
    func availability() async -> ProviderAvailability
    /// Yields zero or more `.partial` chunks, then one `.done`, or throws.
    func respond(to request: AIRequest) -> AsyncThrowingStream<AIChunk, Error>
}

// MARK: - Rules

/// The deterministic answer: always available, instant, and the same for the same input.
public struct RulesProvider: LanguageModelProvider {
    public var kind: AIProviderKind { .rulesEngine }

    public init() {}

    public func availability() async -> ProviderAvailability { .available }

    public func respond(to request: AIRequest) -> AsyncThrowingStream<AIChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch request.task {
                case .explainSignal:
                    guard let signal = request.context.signal else {
                        continuation.finish(throwing: AIError.missingContext)
                        return
                    }
                    let description = await SignalDescriptionEngine().describe(context: signal)
                    continuation.yield(.done(AIAnswer(provider: .rulesEngine, summary: description.explanation,
                                                      recommendation: description.recommendation,
                                                      confidence: description.confidence)))
                case .briefAviation:
                    guard let briefing = request.context.aviation else {
                        continuation.finish(throwing: AIError.missingContext)
                        return
                    }
                    // The digest is counted from the picture; it states facts and does not suggest what to do.
                    continuation.yield(.done(AIAnswer(provider: .rulesEngine,
                                                      summary: ([briefing.headline] + briefing.lines).joined(separator: "\n"),
                                                      recommendation: nil, confidence: "rules / counted")))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Router

public struct AIRouter: Sendable {
    private let providers: [any LanguageModelProvider]
    private let rules: any LanguageModelProvider

    /// Automatic order when the user chose nothing. Private Cloud Compute is deliberately absent.
    static let automaticOrder: [AIProviderKind] = [.foundationOnDevice, .mlxLocal]

    public init(providers: [any LanguageModelProvider], rules: any LanguageModelProvider = RulesProvider()) {
        self.providers = providers
        self.rules = rules
    }

    public func answer(_ request: AIRequest) -> AsyncThrowingStream<AIChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: AIRequest, into continuation: AsyncThrowingStream<AIChunk, Error>.Continuation) async throws {
        let started = ContinuousClock.now
        func elapsed() -> TimeInterval {
            let parts = (ContinuousClock.now - started).components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }

        let rulesAnswer = try await finalAnswer(from: rules.respond(to: request))
        var notes: [String] = []
        let inputs = request.context.inputs

        for kind in candidates(for: request) {
            let name = kind.displayName
            guard let provider = providers.first(where: { $0.kind == kind }) else {
                if kind == request.preferred { notes.append("\(name) is not available in this build.") }
                continue
            }
            if case let .unavailable(reason) = await provider.availability() {
                notes.append("\(name) is unavailable: \(reason)")
                continue
            }

            var grounded = request
            grounded.grounding = [rulesAnswer.summary]
            do {
                var answered: AIAnswer?
                for try await chunk in provider.respond(to: grounded) {
                    switch chunk {
                    case let .partial(text, _): continuation.yield(.partial(text, kind))
                    case let .done(answer): answered = answer
                    }
                }
                guard var answer = answered else { throw AIError.noAnswer }
                answer.provider = kind
                answer.facts = [rulesAnswer.summary]
                answer.inputs = inputs
                answer.notes = notes
                if answer.recommendation == nil, let next = rulesAnswer.recommendation {
                    answer.recommendation = next
                    answer.notes.append("The next step comes from SignalHive Rules.")
                }
                answer.latency = elapsed()
                continuation.yield(.done(answer))
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                notes.append("\(name) failed: \(Self.describe(error))")
            }
        }

        var answer = rulesAnswer
        answer.provider = .rulesEngine
        answer.facts = []
        answer.inputs = inputs
        answer.notes = notes
        answer.latency = elapsed()
        continuation.yield(.done(answer))
    }

    /// Providers to try, in order. Rules only means no model at all; otherwise the user's pick comes first, then the
    /// automatic order. The rules answer is the fallback in every case and is not listed here.
    private func candidates(for request: AIRequest) -> [AIProviderKind] {
        if request.preferred == .rulesEngine { return [] }
        let first = request.preferred.map { [$0] } ?? []
        return first + Self.automaticOrder.filter { $0 != request.preferred }
    }

    /// Framework errors are often not `LocalizedError`; their own description says more than "operation couldn't be completed".
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func finalAnswer(from stream: AsyncThrowingStream<AIChunk, Error>) async throws -> AIAnswer {
        for try await chunk in stream {
            if case let .done(answer) = chunk { return answer }
        }
        throw AIError.noAnswer
    }
}

// MARK: - Prompt and parsing

enum AIPrompt {
    static func prompt(for request: AIRequest) -> String {
        switch request.task {
        case .explainSignal: return explainSignal(request)
        case .briefAviation: return briefAviation(request)
        }
    }

    /// Each fact on its own line, so a multi-line digest reads as a list.
    private static func factLines(_ request: AIRequest) -> [String] {
        request.grounding.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true) }.map { "- \($0)" }
    }

    static func briefAviation(_ request: AIRequest) -> String {
        var lines = [
            "You are the aviation assistant inside SignalHive, a receive-only radio workbench. Write a short plain-language briefing of the air picture below for the operator.",
            "Use only the inputs and facts given. Never contradict the facts. Do not state anything about aircraft or weather that the facts do not. Do not give navigation or flight-safety instructions. If nothing was heard, say so.",
            "",
            "Inputs:",
        ]
        lines += request.context.inputs.map { "- \($0)" }
        if !request.grounding.isEmpty {
            lines += ["", "Facts from SignalHive Rules (true; do not contradict):"]
            lines += factLines(request)
        }
        lines += [
            "",
            "Reply in exactly this format and nothing else:",
            "SUMMARY: <two to four sentences: what is in the air, and any emergency or weather that stands out>",
            "NEXT: <one short sentence: what the operator should keep an eye on>",
            "CONFIDENCE: <high, medium or low>",
        ]
        return lines.joined(separator: "\n")
    }

    /// The model is asked for three labelled lines so the answer can be shown in parts and checked against the facts.
    static func explainSignal(_ request: AIRequest) -> String {
        var lines = [
            "You are the RF assistant inside SignalHive, a receive-only radio workbench. Explain the signal described below to the operator.",
            "Use only the inputs and facts given. Never contradict the facts. Do not claim to have heard or decoded anything. Do not suggest transmitting. If something is unknown, say so.",
            "",
            "Inputs:",
        ]
        lines += request.context.inputs.map { "- \($0)" }
        if !request.grounding.isEmpty {
            lines += ["", "Facts from SignalHive Rules (true; do not contradict):"]
            lines += factLines(request)
        }
        lines += [
            "",
            "Reply in exactly this format and nothing else:",
            "SUMMARY: <one or two sentences on the likely source>",
            "NEXT: <one sentence: the operator's next step>",
            "CONFIDENCE: <high, medium or low>",
        ]
        return lines.joined(separator: "\n")
    }
}

struct ParsedModelAnswer: Equatable {
    var summary: String
    var recommendation: String?
    var confidence: String?
}

enum AIResponseParser {
    private static let labels = ["summary", "next", "confidence"]

    static func parse(_ text: String) -> ParsedModelAnswer {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String: [String]] = [:]
        var preamble: [String] = []
        var current: String?
        for line in trimmed.components(separatedBy: "\n") {
            if let (label, rest) = labelled(line) {
                current = label
                sections[label, default: []].append(rest)
            } else if let current {
                sections[current, default: []].append(line)
            } else {
                preamble.append(line)
            }
        }
        guard !sections.isEmpty else { return ParsedModelAnswer(summary: trimmed, recommendation: nil, confidence: nil) }

        func joined(_ label: String) -> String? {
            guard let lines = sections[label] else { return nil }
            let value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let summary = joined("summary") ?? preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedModelAnswer(summary: summary, recommendation: joined("next"), confidence: joined("confidence")?.lowercased())
    }

    /// What to show while text is still arriving: the summary part, without its label.
    static func displayText(forPartial text: String) -> String { parse(text).summary }

    private static func labelled(_ line: String) -> (String, String)? {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        for label in labels {
            let prefix = label + ":"
            if stripped.lowercased().hasPrefix(prefix) {
                return (label, String(stripped.dropFirst(prefix.count)))
            }
        }
        return nil
    }
}

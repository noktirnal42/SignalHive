import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple's models as providers. They are prompted with plain text and the three-line reply format in `AIPrompt` rather than
// `@Generable`, so this builds as a Swift package, and the same text can be checked against the rules facts.

/// The on-device Foundation Model. Runs on this Mac; nothing is sent anywhere.
public struct FoundationOnDeviceProvider: LanguageModelProvider {
    public var kind: AIProviderKind { .foundationOnDevice }

    public init() {}

    public func availability() async -> ProviderAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This device does not support Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence is turned off in System Settings.")
                case .modelNotReady: return .unavailable("The on-device model is still downloading or preparing.")
                @unknown default: return .unavailable("The on-device model reports it is unavailable.")
                }
            }
        }
        #endif
        return .unavailable("Needs macOS 26 or later with Apple Intelligence.")
    }

    public func respond(to request: AIRequest) -> AsyncThrowingStream<AIChunk, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return FoundationModelsStreaming.stream(kind: kind, request: request) { LanguageModelSession(model: .default) }
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: AIError.noAnswer) }
    }
}

/// Apple's Private Cloud Compute model. The request context leaves this Mac, so `AIRouter` only calls it when the user
/// picks it.
public struct PrivateCloudProvider: LanguageModelProvider {
    public var kind: AIProviderKind { .foundationPrivateCloud }

    public init() {}

    public func availability() async -> ProviderAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, *) {
            switch PrivateCloudComputeLanguageModel().availability {
            case .available:
                return .available
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This device cannot use Private Cloud Compute.")
                case .systemNotReady: return .unavailable("Private Cloud Compute is not ready on this system yet.")
                @unknown default: return .unavailable("Private Cloud Compute reports it is unavailable.")
                }
            }
        }
        #endif
        return .unavailable("Needs macOS 27 or later.")
    }

    public func respond(to request: AIRequest) -> AsyncThrowingStream<AIChunk, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, *) {
            return FoundationModelsStreaming.stream(kind: kind, request: request) {
                LanguageModelSession(model: PrivateCloudComputeLanguageModel())
            }
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: AIError.noAnswer) }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
enum FoundationModelsStreaming {
    /// Streams the model's text, showing the summary part as it arrives, then parses the finished text into an answer.
    static func stream(kind: AIProviderKind, request: AIRequest,
                       makeSession: @escaping @Sendable () -> LanguageModelSession) -> AsyncThrowingStream<AIChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard request.context.hasContent else { throw AIError.missingContext }
                    let session = makeSession()
                    var text = ""
                    for try await snapshot in session.streamResponse(to: AIPrompt.prompt(for: request)) {
                        text = snapshot.content
                        continuation.yield(.partial(AIResponseParser.displayText(forPartial: text), kind))
                    }
                    let parsed = AIResponseParser.parse(text)
                    guard !parsed.summary.isEmpty else { throw AIError.noAnswer }
                    continuation.yield(.done(AIAnswer(provider: kind, summary: parsed.summary,
                                                      recommendation: parsed.recommendation,
                                                      confidence: "model / \(parsed.confidence ?? "not rated")")))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

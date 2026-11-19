import Foundation

/// One message of conversation history as the engine sees it.
///
/// The system prompt travels separately in ``GenerationOptions/systemPrompt``. Assistant turns
/// should carry only the visible answer, not thinking text: Qwen3's chat template drops earlier
/// turns' reasoning, and re-sending it would waste context.
public struct ChatTurn: Hashable, Sendable, Codable {
    public enum Role: String, Hashable, Sendable, Codable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> ChatTurn { ChatTurn(role: .user, text: text) }
    public static func assistant(_ text: String) -> ChatTurn { ChatTurn(role: .assistant, text: text) }
}

/// Per-request generation settings (MLX-free mirror of `GenerateParameters` plus chat options).
public struct GenerationOptions: Hashable, Sendable, Codable {
    public var systemPrompt: String?
    public var temperature: Float
    public var topP: Float
    /// 0 disables top-k.
    public var topK: Int
    /// 0 disables min-p.
    public var minP: Float
    /// Maximum number of generated tokens.
    public var maxTokens: Int
    /// `true`/`false` is passed to the chat template as `enable_thinking`; `nil` passes nothing
    /// (for models whose template has no such switch).
    public var enableThinking: Bool?
    /// The prompt (system + history + new message, after templating) is kept at or under this
    /// many tokens by dropping the oldest turns. The system prompt and the newest user message
    /// are always kept.
    public var promptTokenBudget: Int
    /// Fixed sampling seed (for reproducible tests). `nil` seeds from the clock.
    public var seed: UInt64?

    public init(
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.8,
        topK: Int = 20,
        minP: Float = 0,
        maxTokens: Int = 1024,
        enableThinking: Bool? = nil,
        promptTokenBudget: Int = GenerationOptions.defaultPromptTokenBudget,
        seed: UInt64? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.maxTokens = maxTokens
        self.enableThinking = enableThinking
        self.promptTokenBudget = promptTokenBudget
        self.seed = seed
    }

    /// Default prompt budget. Together with `maxTokens` this bounds the KV cache, so the same
    /// number feeds the memory estimate (see ``DeviceCapability``).
    public static let defaultPromptTokenBudget = 4096

    /// Total context the KV cache may have to hold for one request.
    public var contextTokens: Int { promptTokenBudget + maxTokens }

    /// Options from a model's recommended sampling.
    public static func recommended(
        for spec: ModelSpec, thinking: Bool, systemPrompt: String? = nil,
        promptTokenBudget: Int = defaultPromptTokenBudget
    ) -> GenerationOptions {
        let sampling = spec.recommendedSampling(thinking: thinking)
        return GenerationOptions(
            systemPrompt: systemPrompt,
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            minP: sampling.minP,
            maxTokens: sampling.maxTokens,
            enableThinking: spec.supportsThinkingToggle ? thinking : nil,
            promptTokenBudget: promptTokenBudget)
    }
}

/// Why generation ended.
public enum StopReason: String, Hashable, Sendable, Codable {
    /// The model produced an end-of-sequence token.
    case endOfSequence
    /// ``GenerationOptions/maxTokens`` was reached (reply is truncated).
    case maxTokens
    /// Stopped by the user, by a safety monitor, or because the consumer went away.
    case cancelled

    /// The stop reason an engine should report, given what the library said.
    ///
    /// Works around mlx-swift-lm 3.31.3, which reports `.cancelled` when a reply ends by reaching
    /// `maxTokens`: its generation loop iterates a copy of the `TokenIterator`, so the copy's
    /// token count stays 0 and the "length" check never fires (`MLXLMCommon/Evaluate.swift`,
    /// `generateLoopTask`). If nobody asked to stop and the reply has `maxTokens` tokens, the
    /// limit is what ended it.
    ///
    /// - Parameters:
    ///   - libraryReason: what the library reported.
    ///   - stopRequested: a stop was requested (``InferenceEngine/stopGeneration()``, the
    ///     consumer cancelled the stream, or a safety stop).
    ///   - generatedTokens: tokens generated (excluding the stop token).
    ///   - maxTokens: the request's limit.
    public static func resolved(
        libraryReason: StopReason, stopRequested: Bool, generatedTokens: Int, maxTokens: Int
    ) -> StopReason {
        guard libraryReason == .cancelled, !stopRequested, maxTokens > 0 else { return libraryReason }
        return generatedTokens >= maxTokens ? .maxTokens : .cancelled
    }
}

/// Final numbers for one reply.
public struct GenerationStats: Hashable, Sendable, Codable {
    /// Tokens in the templated prompt after trimming.
    public var promptTokens: Int
    /// Prompt processing (prefill) throughput as reported by the library.
    public var promptTokensPerSecond: Double
    /// Generated tokens (excluding the stop token).
    public var generatedTokens: Int
    /// Decode throughput as reported by the library (generated tokens / decode time).
    public var tokensPerSecond: Double
    /// Seconds from the request start (the `generate` call) to the first visible text.
    /// `nil` if no text was produced.
    public var timeToFirstToken: TimeInterval?
    /// Seconds from the request start to the end of generation.
    public var totalTime: TimeInterval
    public var stopReason: StopReason
    /// Number of history messages dropped to stay within the prompt budget.
    public var droppedMessages: Int
    /// The sampling the engine actually used (`nil` when the reply ended before decoding, and
    /// in conversations saved before it existed).
    public var sampling: SamplingRecord?

    public init(
        promptTokens: Int,
        promptTokensPerSecond: Double,
        generatedTokens: Int,
        tokensPerSecond: Double,
        timeToFirstToken: TimeInterval?,
        totalTime: TimeInterval,
        stopReason: StopReason,
        droppedMessages: Int,
        sampling: SamplingRecord? = nil
    ) {
        self.promptTokens = promptTokens
        self.promptTokensPerSecond = promptTokensPerSecond.finiteOrZero
        self.generatedTokens = generatedTokens
        self.tokensPerSecond = tokensPerSecond.finiteOrZero
        self.timeToFirstToken = timeToFirstToken.map { $0.finiteOrZero }
        self.totalTime = totalTime.finiteOrZero
        self.stopReason = stopReason
        self.droppedMessages = droppedMessages
        self.sampling = sampling
    }
}

/// The sampling settings an engine used for one reply, as it passed them to its library
/// (diagnostics: the self-test reports them per turn).
public struct SamplingRecord: Hashable, Sendable, Codable {
    public var temperature: Float
    public var topP: Float
    /// 0 = top-k off.
    public var topK: Int
    /// 0 = min-p off.
    public var minP: Float
    public var maxTokens: Int
    /// Seed the engine set before sampling (`nil` if it set none).
    public var seed: UInt64?
    /// Whether ``seed`` determines the sampled tokens. `false` for `MLXEngine`: in mlx-swift-lm
    /// 3.31.3 `TopPSampler` and `CategoricalSampler` draw from their own `RandomState`, seeded
    /// from the device uptime when the sampler is created, not from the global seed. (With
    /// `ArgMaxSampler` nothing is random.)
    public var seedControlsSampling: Bool
    /// The sampler the settings selected: `ArgMaxSampler` (temperature 0), `TopPSampler`
    /// (top-p / top-k / min-p filters), `CategoricalSampler`, or `mock`.
    public var sampler: String

    public init(
        temperature: Float, topP: Float, topK: Int, minP: Float, maxTokens: Int, seed: UInt64?,
        seedControlsSampling: Bool, sampler: String
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.maxTokens = maxTokens
        self.seed = seed
        self.seedControlsSampling = seedControlsSampling
        self.sampler = sampler
    }
}

/// Information about the prompt once it has been templated and trimmed (before prefill).
public struct PromptInfo: Hashable, Sendable, Codable {
    public var promptTokens: Int
    public var droppedMessages: Int

    public init(promptTokens: Int, droppedMessages: Int) {
        self.promptTokens = promptTokens
        self.droppedMessages = droppedMessages
    }
}

/// Events of one generation stream, in order: `prompt` (once), `text` (0…n), `finished` (once,
/// unless the consumer itself cancelled the stream).
public enum GenerationEvent: Hashable, Sendable {
    case prompt(PromptInfo)
    /// A decoded text fragment (may contain `<think>` tags; see ``ThinkingParser``).
    case text(String)
    case finished(GenerationStats)
}

/// Errors thrown by engines.
public enum InferenceError: LocalizedError, Equatable, Sendable {
    case noModelLoaded
    /// `detail` is the underlying error's message; `underlyingType` its Swift type name
    /// (`String(reflecting: type(of: error))`), kept for diagnostics such as the self-test.
    case loadFailed(String, underlyingType: String? = nil)
    case generationFailed(String, underlyingType: String? = nil)

    /// Wraps `error` as ``generationFailed(_:underlyingType:)``, keeping its type name.
    public static func generationFailed(wrapping error: any Error) -> InferenceError {
        .generationFailed(
            error.localizedDescription, underlyingType: String(reflecting: type(of: error)))
    }

    /// Wraps `error` as ``loadFailed(_:underlyingType:)``, keeping its type name.
    public static func loadFailed(wrapping error: any Error) -> InferenceError {
        .loadFailed(error.localizedDescription, underlyingType: String(reflecting: type(of: error)))
    }

    /// The wrapped error's type name, if this error wraps one.
    public var underlyingTypeName: String? {
        switch self {
        case .noModelLoaded: nil
        case .loadFailed(_, let type), .generationFailed(_, let type): type
        }
    }

    /// Best type name for diagnostics: the wrapped error's type for engine errors, otherwise
    /// the type of `error` itself.
    public static func typeName(of error: any Error) -> String {
        (error as? InferenceError)?.underlyingTypeName ?? String(reflecting: type(of: error))
    }

    public var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            String(localized: "No model is loaded.", bundle: .module)
        case .loadFailed(let detail, _):
            String(localized: "The model could not be loaded: \(detail)", bundle: .module)
        case .generationFailed(let detail, _):
            String(localized: "Generation failed: \(detail)", bundle: .module)
        }
    }
}

/// Runs a language model. Implementations: `MLXEngine` (app target, real device) and
/// ``MockEngine`` (simulator, tests, previews).
///
/// Concurrency contract:
/// - At most one generation runs at a time. Calling ``generate(_:options:)`` while another is
///   running cancels the earlier one and starts only after its GPU work has finished.
/// - Cancelling the task that iterates the returned stream (or dropping the stream) stops
///   generation promptly; the engine stays usable. In that case the consumer does not get the
///   final `.finished` event.
/// - ``stopGeneration()`` stops the running generation, still delivers its `.finished` event
///   (with ``StopReason/cancelled``) and returns after all GPU work has completed. Use it for a
///   "Stop" button and before the app goes to the background.
public protocol InferenceEngine: AnyObject, Sendable {
    /// Catalog id of the loaded model, or `nil`.
    func loadedModelID() async -> String?

    /// Loads a downloaded model from a local directory. Must not touch the network.
    /// `progress` receives a fraction in 0...1, or `nil` while the fraction is unknown.
    func load(
        _ spec: ModelSpec, from directory: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws

    /// Stops any generation and releases the model's memory.
    func unload() async

    /// Starts generating a reply to `conversation` (oldest first; must end with a user turn).
    func generate(_ conversation: [ChatTurn], options: GenerationOptions)
        -> AsyncThrowingStream<GenerationEvent, Error>

    /// Stops the running generation (if any) and waits until its GPU work has finished.
    func stopGeneration() async

    /// Waits until no generation or load is running.
    func waitUntilIdle() async

    /// Frees cached GPU buffers that are not in use (memory-pressure response).
    func releaseCachedMemory() async
}

extension Double {
    /// Replaces NaN/infinity with 0 (the library divides by measured durations, and JSON
    /// encoding rejects non-finite numbers).
    var finiteOrZero: Double { isFinite ? self : 0 }
}

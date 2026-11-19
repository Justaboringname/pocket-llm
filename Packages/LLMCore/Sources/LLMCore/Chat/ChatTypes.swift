import Foundation

/// A message in the chat UI.
public struct ChatMessage: Identifiable, Hashable, Sendable, Codable {
    public enum Role: String, Hashable, Sendable, Codable {
        case user
        case assistant
    }

    public enum State: Hashable, Sendable, Codable {
        /// The reply is being generated.
        case streaming
        /// Finished normally (see ``ChatMessage/stats`` → `stopReason` for truncation).
        case done
        /// Stopped early (user, thermal safety, or the app leaving the foreground).
        case stopped
        /// Generation failed; the payload is a localized message.
        case failed(String)
    }

    public let id: UUID
    public var role: Role
    /// Visible text (for assistant messages: the answer without thinking).
    public var text: String
    /// Text of the `<think>` block (assistant only; empty if none).
    public var thinking: String
    /// The thinking block never closed (e.g. the token limit was hit while thinking).
    public var isThinkingUnterminated: Bool
    /// Seconds from the first generated text to the end of the thinking block (`</think>`, or
    /// the end of the reply when it never closed). `nil` while still thinking or when the reply
    /// has no thinking block. Optional so conversations saved before it existed still decode.
    public var thinkingDuration: TimeInterval?
    /// `true` when the model ended the reply (end of sequence) inside a thinking block it never
    /// closed and gave no answer, so the thinking text was moved to ``text`` (see
    /// ``promoteUnterminatedThinkingIfNeeded()``). `nil` means no. Optional so conversations
    /// saved before it existed still decode; read it through ``isThinkingPromoted``.
    public var thinkingPromoted: Bool?
    public var state: State
    /// Final statistics (assistant only).
    public var stats: GenerationStats?
    /// Catalog id of the model that produced the reply.
    public var modelID: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        thinking: String = "",
        isThinkingUnterminated: Bool = false,
        thinkingDuration: TimeInterval? = nil,
        thinkingPromoted: Bool? = nil,
        state: State = .done,
        stats: GenerationStats? = nil,
        modelID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.thinking = thinking
        self.isThinkingUnterminated = isThinkingUnterminated
        self.thinkingDuration = thinkingDuration
        self.thinkingPromoted = thinkingPromoted
        self.state = state
        self.stats = stats
        self.modelID = modelID
        self.createdAt = createdAt
    }

    /// The thinking text was shown as the answer (see ``thinkingPromoted``).
    public var isThinkingPromoted: Bool { thinkingPromoted == true }

    /// Handles a finished reply whose model never closed its thinking block and wrote no answer.
    ///
    /// Applies only when the reply is `.done` and ended at the end-of-sequence token (the model
    /// itself stopped), the thinking block is unterminated, the answer is empty or whitespace and
    /// the thinking text is not. Then that text is all the model produced, so it becomes the
    /// answer: ``text`` takes the thinking text, ``thinking`` and ``thinkingDuration`` are
    /// cleared, ``isThinkingUnterminated`` stays `true` and ``thinkingPromoted`` is set. (Seen
    /// with SmolLM3 3B, whose `<think>` tags are plain text: it wrote its reasoning and the whole
    /// answer inside the block and ended without `</think>`.)
    ///
    /// Replies that hit the token limit while thinking, were stopped, or failed keep their
    /// thinking text as thinking.
    ///
    /// - Returns: whether the thinking text was promoted.
    @discardableResult
    public mutating func promoteUnterminatedThinkingIfNeeded() -> Bool {
        guard role == .assistant, state == .done, stats?.stopReason == .endOfSequence,
            isThinkingUnterminated,
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        text = thinking
        thinking = ""
        thinkingDuration = nil
        thinkingPromoted = true
        return true
    }
}

/// User-adjustable chat settings (persisted with the conversation).
public struct ChatSettings: Hashable, Sendable, Codable {
    /// System prompt; empty means none.
    public var systemPrompt: String
    /// Ask models that support it (Qwen3) to think before answering.
    public var thinkingEnabled: Bool
    /// Overrides of the model's recommended sampling; `nil` uses the model default.
    public var temperature: Float?
    public var topP: Float?
    public var maxTokens: Int?
    /// Prompt budget; older turns are dropped beyond it.
    public var promptTokenBudget: Int

    public init(
        systemPrompt: String = "",
        thinkingEnabled: Bool = false,
        temperature: Float? = nil,
        topP: Float? = nil,
        maxTokens: Int? = nil,
        promptTokenBudget: Int = GenerationOptions.defaultPromptTokenBudget
    ) {
        self.systemPrompt = systemPrompt
        self.thinkingEnabled = thinkingEnabled
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.promptTokenBudget = promptTokenBudget
    }

    /// Engine options for `spec` with these settings applied.
    public func options(for spec: ModelSpec) -> GenerationOptions {
        let thinking = spec.supportsThinkingToggle && thinkingEnabled
        var options = GenerationOptions.recommended(
            for: spec, thinking: thinking,
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : systemPrompt,
            promptTokenBudget: promptTokenBudget)
        if let temperature { options.temperature = temperature }
        if let topP { options.topP = topP }
        if let maxTokens { options.maxTokens = maxTokens }
        return options
    }
}

/// What ``ChatViewModel`` persists.
public struct ConversationSnapshot: Hashable, Sendable, Codable {
    public var formatVersion: Int
    public var id: UUID
    public var modelID: String?
    public var settings: ChatSettings
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public init(
        formatVersion: Int = 1, id: UUID, modelID: String?, settings: ChatSettings,
        messages: [ChatMessage], updatedAt: Date
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.modelID = modelID
        self.settings = settings
        self.messages = messages
        self.updatedAt = updatedAt
    }
}

/// Loaded-model state shown by the UI.
public enum ModelSessionState: Hashable, Sendable {
    case noModel
    /// Loading from disk; `progress` is `nil` while unknown (MLX loads have no progress).
    case loading(ModelSpec, progress: Double?)
    case ready(ModelSpec)
    /// Was loaded, then released under memory pressure; it is reloaded on the next message.
    case unloaded(ModelSpec)
    case failed(ModelSpec, message: String)

    public var spec: ModelSpec? {
        switch self {
        case .noModel: nil
        case .loading(let spec, _), .ready(let spec), .unloaded(let spec), .failed(let spec, _):
            spec
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// App lifecycle as seen by the chat (map SwiftUI `ScenePhase` onto it).
public enum AppLifecyclePhase: Hashable, Sendable {
    case active
    /// Transitional (app switcher, Control Center, leaving). GPU work is stopped here already,
    /// because by the time `.background` arrives submitting GPU work may already fail.
    case inactive
    case background
}

/// Live numbers for the reply being generated.
public struct LiveGenerationMetrics: Hashable, Sendable {
    /// When the request started.
    public var startedAt: Date
    /// Prompt size once known.
    public var promptTokens: Int?
    /// Time from request start to the first text; `nil` until it arrives.
    public var timeToFirstToken: TimeInterval?
    /// Text fragments received (≈ tokens; the library streams about one fragment per token).
    public var fragments: Int
    /// Decode speed estimated from fragments since the first one (≈ tokens/s); replaced by the
    /// library's exact figure in the final ``GenerationStats``.
    public var tokensPerSecond: Double?

    public init(startedAt: Date) {
        self.startedAt = startedAt
        self.fragments = 0
    }
}

/// Errors surfaced by ``ChatViewModel`` (localized).
public enum ChatError: LocalizedError, Hashable, Sendable {
    case noModelSelected
    case modelNotDownloaded(String)
    case modelTooLarge(String)
    case deviceTooHot
    case appInBackground
    case busy

    public var errorDescription: String? {
        switch self {
        case .noModelSelected:
            String(localized: "Choose and load a model first.", bundle: .module)
        case .modelNotDownloaded(let name):
            String(localized: "\(name) is not downloaded yet.", bundle: .module)
        case .modelTooLarge(let reason):
            reason
        case .deviceTooHot:
            String(
                localized:
                    "The device is too hot. Generation is paused until it cools down.",
                bundle: .module)
        case .appInBackground:
            String(
                localized: "Generation is not available while the app is in the background.",
                bundle: .module)
        case .busy:
            String(localized: "A reply is still being generated.", bundle: .module)
        }
    }
}

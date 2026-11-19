import Foundation
import Synchronization

/// An ``InferenceEngine`` that streams canned text with fake statistics.
///
/// Used in the simulator (MLX cannot run there), in SwiftUI previews and in tests. It follows
/// the same concurrency contract as the real engine, so UI code exercised against it behaves
/// the same on device.
public actor MockEngine: InferenceEngine {

    public struct Configuration: Sendable {
        /// Delay between text fragments (ignored when a ``TokenGate`` is set).
        public var tokenDelay: Duration
        /// Simulated prompt-processing time.
        public var promptDelay: Duration
        /// Simulated load time.
        public var loadDelay: Duration
        /// When set, every text fragment waits for one ``TokenGate/release(_:)``. Lets tests
        /// stop generation at an exact point.
        public var gate: TokenGate?
        /// Produces the full reply (may include `<think>…</think>`).
        public var responder: @Sendable ([ChatTurn], GenerationOptions) -> String
        /// Makes ``load(_:from:progress:)`` fail with this message.
        public var loadFailure: String?

        public init(
            tokenDelay: Duration = .milliseconds(35),
            promptDelay: Duration = .milliseconds(250),
            loadDelay: Duration = .milliseconds(600),
            gate: TokenGate? = nil,
            responder: @escaping @Sendable ([ChatTurn], GenerationOptions) -> String =
                MockEngine.defaultResponse,
            loadFailure: String? = nil
        ) {
            self.tokenDelay = tokenDelay
            self.promptDelay = promptDelay
            self.loadDelay = loadDelay
            self.gate = gate
            self.responder = responder
            self.loadFailure = loadFailure
        }

        /// No artificial delays (unit tests).
        public static let instant = Configuration(
            tokenDelay: .zero, promptDelay: .zero, loadDelay: .zero)
    }

    private let configuration: Configuration
    private let registry = GenerationTaskRegistry()
    private var loaded: ModelSpec?
    /// Number of `generate` requests that reached the model (tests).
    public private(set) var generationCount = 0
    /// The last conversation passed to `generate` (tests).
    public private(set) var lastConversation: [ChatTurn] = []
    public private(set) var lastOptions: GenerationOptions?
    public private(set) var releaseCount = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func loadedModelID() async -> String? { loaded?.id }

    public func load(
        _ spec: ModelSpec, from directory: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        await registry.cancelAllAndWait()
        loaded = nil
        progress(0)
        if configuration.loadDelay > .zero {
            try await Task.sleep(for: configuration.loadDelay)
        }
        if let failure = configuration.loadFailure {
            throw InferenceError.loadFailed(failure)
        }
        loaded = spec
        progress(1)
    }

    public func unload() async {
        await registry.cancelAllAndWait()
        loaded = nil
    }

    public nonisolated func generate(
        _ conversation: [ChatTurn], options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        let start = ContinuousClock.now
        return registry.makeStream { continuation in
            await self.drive(conversation, options, start: start, continuation: continuation)
        }
    }

    public func stopGeneration() async {
        await registry.cancelAllAndWait()
    }

    public func waitUntilIdle() async {
        await registry.waitForAll()
    }

    public func releaseCachedMemory() async {
        releaseCount += 1
    }

    // MARK: - Driver

    private func drive(
        _ conversation: [ChatTurn], _ options: GenerationOptions, start: ContinuousClock.Instant,
        continuation: GenerationTaskRegistry.Continuation
    ) async {
        guard loaded != nil else {
            continuation.finish(throwing: InferenceError.noModelLoaded)
            return
        }
        generationCount += 1
        lastConversation = conversation
        lastOptions = options

        let promptTokens = Self.approximateTokenCount(conversation, options)
        continuation.yield(.prompt(PromptInfo(promptTokens: promptTokens, droppedMessages: 0)))

        let promptStart = ContinuousClock.now
        if configuration.promptDelay > .zero {
            try? await Task.sleep(for: configuration.promptDelay)
        }
        let promptSeconds = max((ContinuousClock.now - promptStart).seconds, 0.001)

        let fragments = Self.fragments(of: configuration.responder(conversation, options))
        var produced = 0
        var firstTextAt: ContinuousClock.Instant?
        let decodeStart = ContinuousClock.now
        var stopReason = StopReason.endOfSequence

        for fragment in fragments {
            if Task.isCancelled {
                stopReason = .cancelled
                break
            }
            if produced >= options.maxTokens {
                stopReason = .maxTokens
                break
            }
            if let gate = configuration.gate {
                await gate.wait()
            } else if configuration.tokenDelay > .zero {
                try? await Task.sleep(for: configuration.tokenDelay)
            }
            if Task.isCancelled {
                stopReason = .cancelled
                break
            }
            continuation.yield(.text(fragment))
            produced += 1
            if firstTextAt == nil { firstTextAt = .now }
        }

        let end = ContinuousClock.now
        let decodeSeconds = max((end - decodeStart).seconds, 0.001)
        let stats = GenerationStats(
            promptTokens: promptTokens,
            promptTokensPerSecond: Double(promptTokens) / promptSeconds,
            generatedTokens: produced,
            tokensPerSecond: Double(produced) / decodeSeconds,
            timeToFirstToken: firstTextAt.map { ($0 - start).seconds },
            totalTime: (end - start).seconds,
            stopReason: stopReason,
            droppedMessages: 0,
            sampling: SamplingRecord(
                temperature: options.temperature, topP: options.topP, topK: options.topK,
                minP: options.minP, maxTokens: options.maxTokens, seed: options.seed,
                seedControlsSampling: false, sampler: "mock"))
        continuation.yield(.finished(stats))
        continuation.finish()
    }

    // MARK: - Canned replies

    /// Default reply: answers "double it" follow-ups using the number from the previous assistant
    /// turn (so multi-turn flows, including the self-test, can be checked in the simulator),
    /// otherwise a fixed sentence. Adds a short `<think>` block when thinking is on.
    public static let defaultResponse: @Sendable ([ChatTurn], GenerationOptions) -> String = {
        conversation, options in
        let lastUser = conversation.last(where: { $0.role == .user })?.text ?? ""
        let answer: String
        if lastUser.lowercased().contains("double"),
            let previous = conversation.last(where: { $0.role == .assistant }),
            let number = firstInteger(in: previous.text)
        {
            answer = "\(number * 2)"
        } else if lastUser.lowercased().contains("number") {
            answer = "27"
        } else {
            answer =
                "This is a simulated reply from the mock engine. Real models run only on a physical device with Apple silicon GPU support."
        }
        if options.enableThinking == true {
            return "<think>\nThe user wrote: \(lastUser.prefix(60)). I will answer briefly.\n</think>\n\n\(answer)"
        }
        return answer
    }

    static func firstInteger(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    /// Splits text into word-sized fragments (keeping whitespace) so tags are often split
    /// across fragments, like real tokenizer output.
    static func fragments(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n" || current.count >= 4 {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func approximateTokenCount(_ conversation: [ChatTurn], _ options: GenerationOptions)
        -> Int
    {
        let characters =
            conversation.reduce(0) { $0 + $1.text.count } + (options.systemPrompt?.count ?? 0)
        return max(1, characters / 4) + 4 * conversation.count
    }
}

/// Lets a test release mock tokens one at a time. Waiting is cancellation-aware, so stopping a
/// generation that is blocked on the gate returns promptly.
public final class TokenGate: Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var permits = 0
        var waiters: [Waiter] = []
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Allows `count` more fragments to be produced.
    public func release(_ count: Int = 1) {
        let toResume: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.permits += count
            var resumed: [CheckedContinuation<Void, Never>] = []
            while state.permits > 0, !state.waiters.isEmpty {
                state.permits -= 1
                resumed.append(state.waiters.removeFirst().continuation)
            }
            return resumed
        }
        for continuation in toResume { continuation.resume() }
    }

    /// Releases everything currently waiting and all future waits.
    public func open() {
        release(1_000_000)
    }

    /// Number of producers currently blocked on the gate.
    public var waitingCount: Int {
        state.withLock { $0.waiters.count }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return true }
                    if state.permits > 0 {
                        state.permits -= 1
                        return true
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiting: CheckedContinuation<Void, Never>? = state.withLock { state in
                if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                    return state.waiters.remove(at: index).continuation
                }
                state.cancelled.insert(id)
                return nil
            }
            waiting?.resume()
        }
    }
}

extension Duration {
    /// The duration in seconds as a `Double`.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

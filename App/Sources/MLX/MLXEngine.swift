import Foundation
import LLMCore
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// ``InferenceEngine`` backed by MLX (mlx-swift-lm). The only engine that touches the GPU.
///
/// Loading is network-free by construction: the model is described as a local
/// `.directory` configuration and the factory receives ``OfflineOnlyDownloader``, which throws if
/// anything ever asks it to fetch. mlx-swift-lm's `resolve()` does not call the downloader for
/// `.directory` configurations, and the tokenizer is read with `AutoTokenizer.from(modelFolder:)`
/// (local files only).
///
/// Multi-turn: the whole (trimmed) conversation is templated and prefilled for every reply; no
/// KV cache is kept between replies. See `PromptBuilder` for the trimming rule.
actor MLXEngine: InferenceEngine {
    /// GPU buffer-cache limit, as in the mlx-swift-examples LLMEval app.
    static let gpuCacheLimitBytes = 20 * 1024 * 1024

    private var container: ModelContainer?
    private var loadedSpec: ModelSpec?
    private var pendingLoad: Task<ModelContainer, Error>?
    /// Bumped by every load/unload so a slow load cannot resurrect a model that was unloaded or
    /// replaced while it was running.
    private var epoch = 0
    private let registry = GenerationTaskRegistry()

    init() {}

    // MARK: - Loading

    func loadedModelID() async -> String? { loadedSpec?.id }

    func load(
        _ spec: ModelSpec, from directory: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        await registry.cancelAllAndWait()
        if let pendingLoad { _ = try? await pendingLoad.value }

        epoch += 1
        let myEpoch = epoch
        // Release the previous model first so peak memory is not old + new.
        container = nil
        loadedSpec = nil
        Memory.clearCache()
        Memory.cacheLimit = Self.gpuCacheLimitBytes
        progress(nil)  // mlx-swift-lm reports no progress for local loads

        let configuration = ModelConfiguration(
            directory: directory, extraEOSTokens: Set(spec.extraEOSTokens))
        let task = Task<ModelContainer, Error> {
            try await LLMModelFactory.shared.loadContainer(
                from: OfflineOnlyDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration)
        }
        pendingLoad = task
        defer { if epoch == myEpoch { pendingLoad = nil } }

        let loaded: ModelContainer
        do {
            loaded = try await task.value
        } catch {
            throw InferenceError.loadFailed(wrapping: error)
        }
        guard epoch == myEpoch else { throw CancellationError() }
        container = loaded
        loadedSpec = spec
        progress(1)
    }

    func unload() async {
        await registry.cancelAllAndWait()
        epoch += 1
        if let pendingLoad { _ = try? await pendingLoad.value }
        pendingLoad = nil
        container = nil
        loadedSpec = nil
        Memory.clearCache()
    }

    // MARK: - Generation

    nonisolated func generate(
        _ conversation: [ChatTurn], options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        let requestStart = ContinuousClock.now
        return registry.makeStream { continuation in
            await self.drive(
                conversation, options: options, requestStart: requestStart,
                continuation: continuation)
        }
    }

    func stopGeneration() async {
        await registry.cancelAllAndWait()
    }

    func waitUntilIdle() async {
        await registry.waitForAll()
        if let pendingLoad { _ = try? await pendingLoad.value }
    }

    func releaseCachedMemory() async {
        Memory.clearCache()
    }

    /// Prefill and decode for one request. Runs inside a registry driver task; cancellation of
    /// that task (stop, or the consumer going away) cancels the MLX generation loop, waits for
    /// it, and still reports `.finished` with `.cancelled`.
    private func drive(
        _ conversation: [ChatTurn], options: GenerationOptions,
        requestStart: ContinuousClock.Instant,
        continuation: GenerationTaskRegistry.Continuation
    ) async {
        guard let container else {
            continuation.finish(throwing: InferenceError.noModelLoaded)
            return
        }

        var prompt: PromptBuilder.Prompt?
        do {
            // 1. Template and trim the conversation (tokenizer only, no GPU).
            let built = try await container.perform { context in
                try PromptBuilder.build(conversation, options: options, context: context)
            }
            prompt = built
            continuation.yield(
                .prompt(
                    PromptInfo(promptTokens: built.tokens.count, droppedMessages: built.droppedMessages)))
            try Task.checkCancellation()

            // 2. Prefill (synchronous inside TokenIterator.init) and start decoding.
            let parameters = GenerateParameters(
                maxTokens: options.maxTokens,
                temperature: options.temperature,
                topP: options.topP,
                topK: options.topK,
                minP: options.minP)
            // Note: in mlx-swift-lm 3.31.3 this global seed does not reach sampling. TopPSampler
            // and CategoricalSampler sample inside withRandomState(own RandomState()), seeded
            // from the uptime (Evaluate.swift 232/241, 300/304); see SamplingRecord.
            let seed = options.seed ?? UInt64(Date().timeIntervalSince1970 * 1000)
            MLXRandom.seed(seed)
            let tokens = built.tokens
            let running = try await container.perform { context in
                let input = LMInput(tokens: MLXArray(tokens))
                let iterator = try TokenIterator(
                    input: input, model: context.model, cache: nil, parameters: parameters)
                // TokenIterator(…parameters:) builds its sampler with parameters.sampler(); the
                // same call here names the type it chose (diagnostics only).
                let samplerName = String(describing: type(of: parameters.sampler()))
                let (stream, task) = generateTask(
                    promptTokenCount: tokens.count,
                    modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer,
                    iterator: iterator)
                return RunningGeneration(stream: stream, task: task, samplerName: samplerName)
            }
            let sampling = SamplingRecord(
                temperature: parameters.temperature, topP: parameters.topP,
                topK: parameters.topK, minP: parameters.minP, maxTokens: options.maxTokens,
                seed: seed, seedControlsSampling: false, sampler: running.samplerName)

            // 3. Forward events from a task that is NOT cancelled together with this driver, so
            //    the library's final `.info` (with stopReason .cancelled) still arrives after a
            //    stop. Cancelling this driver cancels the library task instead.
            let pump = Task { () -> (GenerateCompletionInfo?, ContinuousClock.Instant?) in
                var info: GenerateCompletionInfo?
                var firstText: ContinuousClock.Instant?
                for await item in running.stream {
                    switch item {
                    case .chunk(let text):
                        if firstText == nil { firstText = .now }
                        continuation.yield(.text(text))
                    case .info(let value):
                        info = value
                    case .toolCall:
                        break
                    }
                }
                return (info, firstText)
            }
            let (info, firstText) = await withTaskCancellationHandler {
                await pump.value
            } onCancel: {
                running.task.cancel()
            }
            // This driver is cancelled only by a requested stop: stopGeneration() (user or
            // safety), the consumer dropping the stream, or a newer generation replacing it.
            let stopRequested = Task.isCancelled
            // The library task ends with Stream().synchronize(): all GPU work is done after this.
            await running.task.value

            // mlx-swift-lm 3.31.3 reports `.cancelled` when the reply reached maxTokens; see
            // StopReason.resolved(libraryReason:stopRequested:generatedTokens:maxTokens:).
            let stopReason = StopReason.resolved(
                libraryReason: info.map { StopReason($0.stopReason) } ?? .cancelled,
                stopRequested: stopRequested,
                generatedTokens: info?.generationTokenCount ?? 0,
                maxTokens: options.maxTokens)

            let end = ContinuousClock.now
            continuation.yield(
                .finished(
                    GenerationStats(
                        promptTokens: info?.promptTokenCount ?? tokens.count,
                        promptTokensPerSecond: info?.promptTokensPerSecond ?? 0,
                        generatedTokens: info?.generationTokenCount ?? 0,
                        tokensPerSecond: info?.tokensPerSecond ?? 0,
                        timeToFirstToken: firstText.map { seconds($0 - requestStart) },
                        totalTime: seconds(end - requestStart),
                        stopReason: stopReason,
                        droppedMessages: built.droppedMessages,
                        sampling: sampling)))
            continuation.finish()
        } catch is CancellationError {
            // Stopped after templating but before decoding started.
            continuation.yield(
                .finished(
                    GenerationStats(
                        promptTokens: prompt?.tokens.count ?? 0,
                        promptTokensPerSecond: 0,
                        generatedTokens: 0,
                        tokensPerSecond: 0,
                        timeToFirstToken: nil,
                        totalTime: seconds(ContinuousClock.now - requestStart),
                        stopReason: .cancelled,
                        droppedMessages: prompt?.droppedMessages ?? 0)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: InferenceError.generationFailed(wrapping: error))
        }
    }
}

/// The library's generation stream plus the task that drives it.
private struct RunningGeneration: Sendable {
    let stream: AsyncStream<Generation>
    let task: Task<Void, Never>
    /// Type name of the sampler the parameters selected (e.g. `TopPSampler`).
    let samplerName: String
}

/// Builds the prompt tokens for a conversation, trimming the oldest messages to fit the
/// budget.
///
/// Rule: render `[system?] + history` with the model's chat template (`enable_thinking` passed
/// through `additionalContext`), count tokens, and while the count exceeds
/// `options.promptTokenBudget`, drop the oldest message and then any non-user messages until
/// the history starts with a user message again. The system prompt and the newest user message
/// are never dropped. Mirrors `LLMUserInputProcessor.prepare` in mlx-swift-lm (message
/// generator + `applyChatTemplate`, plain-text fallback when there is no template).
enum PromptBuilder {
    struct Prompt: Sendable {
        let tokens: [Int]
        let droppedMessages: Int
    }

    static func build(
        _ conversation: [ChatTurn], options: GenerationOptions, context: ModelContext
    ) throws -> Prompt {
        let generator: any MessageGenerator =
            (context.model as? any LLMModel)?.messageGenerator(tokenizer: context.tokenizer)
            ?? DefaultMessageGenerator()
        let additionalContext: [String: any Sendable]? = options.enableThinking.map {
            ["enable_thinking": $0]
        }

        var turns = conversation
        var dropped = 0
        while true {
            var chat: [Chat.Message] = []
            if let system = options.systemPrompt, !system.isEmpty {
                chat.append(.system(system))
            }
            for turn in turns {
                chat.append(turn.role == .user ? .user(turn.text) : .assistant(turn.text))
            }
            let tokens: [Int]
            do {
                tokens = try context.tokenizer.applyChatTemplate(
                    messages: generator.generate(messages: chat), tools: nil,
                    additionalContext: additionalContext)
            } catch MLXLMCommon.TokenizerError.missingChatTemplate {
                tokens = context.tokenizer.encode(
                    text: chat.map(\.content).joined(separator: "\n\n"))
            }

            if tokens.count <= options.promptTokenBudget || turns.count <= 1 {
                return Prompt(tokens: tokens, droppedMessages: dropped)
            }
            turns.removeFirst()
            dropped += 1
            while turns.count > 1, let first = turns.first, first.role != .user {
                turns.removeFirst()
                dropped += 1
            }
        }
    }
}

/// A `Downloader` that refuses to download. Passing it to the model factory makes "loading
/// never touches the network" a structural property instead of a convention.
struct OfflineOnlyDownloader: Downloader {
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        throw OfflineLoadError.downloadAttempted(id)
    }
}

enum OfflineLoadError: LocalizedError {
    case downloadAttempted(String)

    var errorDescription: String? {
        switch self {
        case .downloadAttempted(let id):
            "Internal error: loading tried to download \(id). Models must be loaded from disk."
        }
    }
}

extension StopReason {
    init(_ reason: GenerateStopReason) {
        switch reason {
        case .stop: self = .endOfSequence
        case .length: self = .maxTokens
        case .cancelled: self = .cancelled
        }
    }
}

private func seconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) + Double(attoseconds) / 1e18
}

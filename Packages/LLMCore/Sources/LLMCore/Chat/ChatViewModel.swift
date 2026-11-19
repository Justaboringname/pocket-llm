import Foundation
import Observation

/// App state for the chat screen: messages, the loaded model, live metrics, safety reactions
/// and persistence. The UI talks only to this type (and to a ``ModelStore`` for the model
/// list); it never touches MLX.
///
/// Typical use:
/// ```swift
/// let chat = ChatViewModel(engine: engine, store: store, safety: SafetyMonitor(),
///                          persistence: FileConversationStore(fileURL: …))
/// chat.restore()
/// try await chat.loadModel(spec)
/// await chat.send("Hello")      // returns when the reply is complete or stopped
/// await chat.stop()             // from a Stop button
/// ```
@Observable
@MainActor
public final class ChatViewModel {

    // MARK: - Observable state

    /// The conversation, oldest first. The last message is `.streaming` while a reply runs.
    public private(set) var messages: [ChatMessage] = []
    /// A reply is being produced (including an automatic model reload before it).
    public private(set) var isGenerating = false
    /// Live numbers for the in-flight reply (`nil` when idle).
    public private(set) var live: LiveGenerationMetrics?
    /// The current model and whether it is loaded.
    public private(set) var modelState: ModelSessionState = .noModel
    /// Memory fit of the current model at load time.
    public private(set) var currentModelFit: MemoryFit?
    /// Last user-facing error (localized), cleared on the next successful action.
    public private(set) var lastError: String?
    /// Swift type name of the error behind the last failed load or reply (for engine errors,
    /// the wrapped error's type). Diagnostics only (the self-test reports it); not localized.
    public private(set) var lastErrorType: String?
    public private(set) var lifecycle: AppLifecyclePhase = .active
    public private(set) var conversationID = UUID()
    /// Model to offer after relaunch (the last one loaded).
    public private(set) var preferredModelID: String?
    /// Chat settings; changes are persisted.
    public var settings = ChatSettings() {
        didSet { persist() }
    }

    /// Convenience: the current model, loaded or not.
    public var currentModel: ModelSpec? { modelState.spec }

    // MARK: - Dependencies

    @ObservationIgnored public let engine: any InferenceEngine
    @ObservationIgnored public let store: any ModelStore
    @ObservationIgnored public let safety: SafetyMonitor
    @ObservationIgnored public let capability: DeviceCapability
    @ObservationIgnored private let persistence: (any ConversationPersisting)?

    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: (id: String, task: Task<Void, Error>)?
    @ObservationIgnored private var stopCause: StopCause?
    @ObservationIgnored private var lastStreamingSave = Date.distantPast

    /// Minimum interval between saves while a reply streams.
    @ObservationIgnored public var streamingSaveInterval: TimeInterval = 3

    private enum StopCause {
        case user
        case thermal
        case lifecycle
    }

    public init(
        engine: any InferenceEngine,
        store: any ModelStore,
        safety: SafetyMonitor,
        capability: DeviceCapability = DeviceCapability(),
        persistence: (any ConversationPersisting)? = nil
    ) {
        self.engine = engine
        self.store = store
        self.safety = safety
        self.capability = capability
        self.persistence = persistence
        safety.onThermalLevelChange = { [weak self] level in
            self?.thermalLevelChanged(level)
        }
    }

    // MARK: - Persistence

    /// Restores the persisted conversation and settings (call once at launch). Replies that were
    /// streaming when the app died are marked stopped.
    public func restore() {
        guard let persistence, let snapshot = try? persistence.load() else { return }
        conversationID = snapshot.id
        preferredModelID = snapshot.modelID
        messages = snapshot.messages.map { message in
            var message = message
            if message.state == .streaming { message.state = .stopped }
            return message
        }
        withoutPersisting { settings = snapshot.settings }
    }

    // MARK: - Model

    /// Memory fit for `spec` measured now (accounts for memory the current model would free).
    public func memoryFit(for spec: ModelSpec) -> MemoryFit {
        capability.fit(
            for: spec, contextTokens: settings.options(for: spec).contextTokens,
            reclaimableBytes: reclaimableBytes(replacing: spec))
    }

    /// Loads `spec` from the store. Refuses models that do not fit in memory.
    public func loadModel(_ spec: ModelSpec) async throws {
        if let loadTask, loadTask.id == spec.id {
            try await loadTask.task.value
            return
        }
        guard lifecycle == .active else { throw fail(.appInBackground) }
        guard let directory = store.localDirectory(for: spec) else {
            throw fail(.modelNotDownloaded(spec.displayName))
        }
        if case .ready(let current) = modelState, current.id == spec.id,
            await engine.loadedModelID() == spec.id
        {
            return
        }
        if generationTask != nil { await stop() }

        let fit = memoryFit(for: spec)
        if case .tooLarge(let reason) = fit {
            modelState = .failed(spec, message: reason)
            throw fail(.modelTooLarge(reason))
        }

        modelState = .loading(spec, progress: nil)
        lastErrorType = nil
        let engine = self.engine
        let report: @Sendable (Double?) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, case .loading(let loading, _) = self.modelState,
                    loading.id == spec.id
                else { return }
                self.modelState = .loading(spec, progress: progress)
            }
        }
        let task = Task<Void, Error> {
            try await engine.load(spec, from: directory, progress: report)
        }
        loadTask = (spec.id, task)
        defer {
            if loadTask?.id == spec.id { loadTask = nil }
        }
        do {
            try await task.value
            modelState = .ready(spec)
            currentModelFit = fit
            preferredModelID = spec.id
            lastError = nil
            persist()
        } catch {
            let message = error.localizedDescription
            modelState = .failed(spec, message: message)
            lastError = message
            lastErrorType = InferenceError.typeName(of: error)
            throw error
        }
    }

    /// Unloads the current model (keeps it selected; it reloads on the next message).
    public func unloadModel() async {
        if generationTask != nil { await stop() }
        guard let spec = modelState.spec else { return }
        modelState = .unloaded(spec)
        await engine.unload()
    }

    /// Stops any reply, unloads the current model and forgets the selection, so the state is
    /// ``ModelSessionState/noModel`` again (e.g. before the model's files are deleted). The
    /// conversation is kept.
    public func clearModel() async {
        await stop(cause: .user)
        guard modelState.spec != nil else { return }
        modelState = .noModel
        currentModelFit = nil
        preferredModelID = nil
        await engine.unload()
        persist()
    }

    // MARK: - Chat

    /// Sends a user message and generates the reply. Returns `false` if the message was not
    /// sent (empty, busy, no model, too hot, backgrounded; see ``lastError``).
    @discardableResult
    public func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isGenerating else {
            lastError = ChatError.busy.localizedDescription
            return false
        }
        guard let spec = try? checkCanGenerate() else { return false }
        isGenerating = true
        defer { isGenerating = false }
        guard await ensureLoaded(spec) else { return false }
        lastError = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        await runReply(spec: spec)
        return true
    }

    /// Discards the last reply and generates a new one for the same user message.
    @discardableResult
    public func regenerate() async -> Bool {
        guard !isGenerating else { return false }
        guard let spec = try? checkCanGenerate() else { return false }
        guard messages.contains(where: { $0.role == .user }) else { return false }
        isGenerating = true
        defer { isGenerating = false }
        guard await ensureLoaded(spec) else { return false }
        while let last = messages.last, last.role == .assistant {
            messages.removeLast()
        }
        lastError = nil
        await runReply(spec: spec)
        return true
    }

    /// Stops the running reply and waits until the engine is idle. The partial reply is kept
    /// and marked `.stopped`.
    public func stop() async {
        await stop(cause: .user)
    }

    /// Clears the conversation (stopping any reply first).
    public func newConversation() async {
        await stop(cause: .user)
        messages = []
        conversationID = UUID()
        lastError = nil
        persist()
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: - System events

    /// Memory warning: free cached GPU buffers, and unload the model if no reply is running.
    public func handleMemoryWarning() async {
        await engine.releaseCachedMemory()
        guard !isGenerating, loadTask == nil, case .ready(let spec) = modelState else { return }
        modelState = .unloaded(spec)
        await engine.unload()
    }

    /// Lifecycle changes: leaving the foreground stops generation and waits for the GPU to be
    /// idle (iOS terminates apps that submit GPU work in the background). New work is refused
    /// until the app is active again.
    public func handleLifecycle(_ phase: AppLifecyclePhase) async {
        lifecycle = phase
        switch phase {
        case .active:
            break
        case .inactive, .background:
            await stop(cause: .lifecycle)
            await engine.waitUntilIdle()
            persist()
        }
    }

    // MARK: - Internals

    private func checkCanGenerate() throws -> ModelSpec {
        guard lifecycle == .active else { throw fail(.appInBackground) }
        guard !safety.isGenerationBlocked else { throw fail(.deviceTooHot) }
        guard let spec = modelState.spec else { throw fail(.noModelSelected) }
        return spec
    }

    private func ensureLoaded(_ spec: ModelSpec) async -> Bool {
        if modelState.isReady { return true }
        do {
            try await loadModel(spec)
            return true
        } catch {
            if lastError == nil { lastError = error.localizedDescription }
            return false
        }
    }

    private func runReply(spec: ModelSpec) async {
        let assistant = ChatMessage(
            role: .assistant, text: "", state: .streaming, modelID: spec.id)
        let turns = historyTurns()
        messages.append(assistant)
        persist()

        let options = settings.options(for: spec)
        stopCause = nil
        lastErrorType = nil
        let start = Date()
        live = LiveGenerationMetrics(startedAt: start)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.consume(
                assistantID: assistant.id, turns: turns, options: options, start: start)
        }
        generationTask = task
        await task.value
        generationTask = nil
        live = nil
        if stopCause == .thermal {
            lastError = ChatError.deviceTooHot.localizedDescription
        }
        stopCause = nil
        persist()
    }

    private func consume(
        assistantID: UUID, turns: [ChatTurn], options: GenerationOptions, start: Date
    ) async {
        var parser = ThinkingParser()
        var finalStats: GenerationStats?
        var failure: String?
        var firstFragmentAt: Date?
        var thinkingDuration: TimeInterval?
        var fragments = 0
        var promptTokens = 0

        do {
            for try await event in engine.generate(turns, options: options) {
                switch event {
                case .prompt(let info):
                    promptTokens = info.promptTokens
                    live?.promptTokens = info.promptTokens
                case .text(let fragment):
                    let now = Date()
                    fragments += 1
                    if firstFragmentAt == nil {
                        firstFragmentAt = now
                        live?.timeToFirstToken = now.timeIntervalSince(start)
                    }
                    live?.fragments = fragments
                    if let first = firstFragmentAt, fragments > 1 {
                        live?.tokensPerSecond =
                            Double(fragments - 1) / max(now.timeIntervalSince(first), 0.001)
                    }
                    _ = parser.feed(fragment)
                    if thinkingDuration == nil, parser.isThinkingClosed, let first = firstFragmentAt {
                        thinkingDuration = now.timeIntervalSince(first)
                    }
                    updateMessage(assistantID) {
                        $0.text = parser.answerText
                        $0.thinking = parser.thinkingText
                        $0.thinkingDuration = thinkingDuration
                    }
                    persistWhileStreaming()
                case .finished(let stats):
                    finalStats = stats
                }
            }
        } catch is CancellationError {
            // Stream ended because the consumer side was cancelled; handled below.
        } catch {
            failure = error.localizedDescription
            lastErrorType = InferenceError.typeName(of: error)
        }

        _ = parser.finish()
        let wasStopped = stopCause != nil
        let end = Date()
        if thinkingDuration == nil, parser.hasThinkingBlock, let first = firstFragmentAt {
            thinkingDuration = end.timeIntervalSince(first)
        }
        let stats =
            finalStats
            ?? GenerationStats(
                promptTokens: promptTokens,
                promptTokensPerSecond: 0,
                generatedTokens: fragments,
                tokensPerSecond: firstFragmentAt.map {
                    Double(max(fragments - 1, 0)) / max(end.timeIntervalSince($0), 0.001)
                } ?? 0,
                timeToFirstToken: firstFragmentAt.map { $0.timeIntervalSince(start) },
                totalTime: end.timeIntervalSince(start),
                stopReason: .cancelled,
                droppedMessages: 0)
        updateMessage(assistantID) { message in
            message.text = parser.answerText
            message.thinking = parser.thinkingText
            message.isThinkingUnterminated = parser.isThinkingUnterminated
            message.thinkingDuration = thinkingDuration
            message.stats = failure == nil || finalStats != nil ? stats : nil
            if let failure {
                message.state = .failed(failure)
            } else if wasStopped || stats.stopReason == .cancelled {
                message.state = .stopped
            } else {
                message.state = .done
            }
            // The model ended inside a thinking block it never closed, with no answer: show that
            // text as the answer (a `.maxTokens`, stopped or failed reply keeps it as thinking).
            message.promoteUnterminatedThinkingIfNeeded()
        }
        if let failure { lastError = failure }
    }

    private func stop(cause: StopCause) async {
        guard let task = generationTask else {
            if let loadTask { _ = try? await loadTask.task.value }
            return
        }
        if stopCause == nil { stopCause = cause }
        await engine.stopGeneration()
        await task.value
    }

    private func thermalLevelChanged(_ level: ThermalLevel) {
        guard level >= .critical, generationTask != nil else { return }
        Task { await self.stop(cause: .thermal) }
    }

    /// History for the engine: user text and assistant answers (thinking and failed or empty
    /// replies are not sent back). A promoted reply (``ChatMessage/thinkingPromoted``) is sent
    /// back as its answer text, which is what the user saw.
    private func historyTurns() -> [ChatTurn] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                return .user(message.text)
            case .assistant:
                if case .failed = message.state { return nil }
                let answer = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return answer.isEmpty ? nil : .assistant(answer)
            }
        }
    }

    private func updateMessage(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func reclaimableBytes(replacing spec: ModelSpec) -> Int64 {
        let isResident: Bool
        switch modelState {
        case .ready, .loading: isResident = true
        case .noModel, .unloaded, .failed: isResident = false
        }
        guard isResident, let current = modelState.spec, current.id != spec.id else { return 0 }
        return DeviceCapability.estimate(
            for: current, contextTokens: settings.options(for: current).contextTokens
        ).totalBytes
    }

    private func fail(_ error: ChatError) -> ChatError {
        lastError = error.localizedDescription
        return error
    }

    // MARK: Persistence helpers

    @ObservationIgnored private var persistenceSuspended = false

    private func withoutPersisting(_ body: () -> Void) {
        persistenceSuspended = true
        body()
        persistenceSuspended = false
    }

    private func persist() {
        guard let persistence, !persistenceSuspended else { return }
        let snapshot = ConversationSnapshot(
            id: conversationID, modelID: preferredModelID, settings: settings,
            messages: messages, updatedAt: Date())
        try? persistence.save(snapshot)
        lastStreamingSave = Date()
    }

    private func persistWhileStreaming() {
        guard Date().timeIntervalSince(lastStreamingSave) >= streamingSaveInterval else { return }
        persist()
    }
}

extension ChatViewModel {
    /// A view model wired to mocks, for SwiftUI previews.
    public static func preview(downloaded: Set<String> = [ModelCatalog.qwen3_0_6B.id])
        -> ChatViewModel
    {
        ChatViewModel(
            engine: MockEngine(),
            store: MockModelStore(downloaded: downloaded),
            safety: SafetyMonitor(observeSystemNotifications: false),
            capability: DeviceCapability(measure: {
                MemorySnapshot(
                    physicalMemoryBytes: 12 << 30, footprintBytes: 200 << 20,
                    availableBytes: 6 << 30)
            }))
    }
}

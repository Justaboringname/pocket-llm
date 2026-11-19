import Foundation
import Testing

@testable import LLMCore

@MainActor
@Suite("ChatViewModel")
struct ChatViewModelTests {
    let spec = ModelCatalog.qwen3_0_6B
    let roomyMemory = DeviceCapability(measure: {
        MemorySnapshot(
            physicalMemoryBytes: 12 << 30, footprintBytes: 100 << 20, availableBytes: 6 << 30)
    })

    private func makeViewModel(
        engine: MockEngine = MockEngine(configuration: .instant),
        persistence: (any ConversationPersisting)? = nil,
        safety: SafetyMonitor = SafetyMonitor(
            readThermalState: { .nominal }, observeSystemNotifications: false),
        capability: DeviceCapability? = nil
    ) -> ChatViewModel {
        ChatViewModel(
            engine: engine,
            store: MockModelStore(downloaded: [spec.id]),
            safety: safety,
            capability: capability ?? roomyMemory,
            persistence: persistence)
    }

    @Test func sendWithoutModelIsRefused() async {
        let viewModel = makeViewModel()
        let sent = await viewModel.send("Hi")
        #expect(sent == false)
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.lastError == ChatError.noModelSelected.localizedDescription)
    }

    @Test func loadAndSendProducesCompletedReplyWithStats() async throws {
        let viewModel = makeViewModel()
        try await viewModel.loadModel(spec)
        #expect(viewModel.modelState == .ready(spec))
        #expect(viewModel.currentModelFit == .ok)

        let sent = await viewModel.send("  Hello there  ")
        #expect(sent)
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages[0].role == .user)
        #expect(viewModel.messages[0].text == "Hello there")
        let reply = viewModel.messages[1]
        #expect(reply.role == .assistant)
        #expect(reply.state == .done)
        #expect(reply.text.hasPrefix("This is a simulated reply"))
        #expect(reply.modelID == spec.id)
        let stats = try #require(reply.stats)
        #expect(stats.stopReason == .endOfSequence)
        #expect(stats.generatedTokens > 0)
        #expect(stats.promptTokens > 0)
        #expect(stats.timeToFirstToken != nil)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.live == nil)
    }

    @Test func streamingShowsLiveStateThenStopKeepsPartialReply() async throws {
        let gate = TokenGate()
        var configuration = MockEngine.Configuration.instant
        configuration.gate = gate
        let engine = MockEngine(configuration: configuration)
        let viewModel = makeViewModel(engine: engine)
        try await viewModel.loadModel(spec)

        let sending = Task { await viewModel.send("Tell me something") }
        try await waitUntil { viewModel.messages.last?.state == .streaming }
        #expect(viewModel.isGenerating)

        gate.release(3)
        try await waitUntil { (viewModel.live?.fragments ?? 0) == 3 }
        let partial = try #require(viewModel.messages.last?.text)
        #expect(partial.isEmpty == false)
        #expect(viewModel.live?.timeToFirstToken != nil)
        #expect(viewModel.live?.promptTokens != nil)

        await viewModel.stop()
        _ = await sending.value

        let reply = try #require(viewModel.messages.last)
        #expect(reply.state == .stopped)
        #expect(reply.text == partial)
        #expect(reply.stats?.stopReason == .cancelled)
        #expect(reply.stats?.generatedTokens == 3)
        #expect(viewModel.isGenerating == false)

        // The engine is reusable after a stop.
        gate.open()
        #expect(await viewModel.send("And now a number please"))
        #expect(viewModel.messages.last?.state == .done)
        #expect(viewModel.messages.last?.text == "27")
    }

    @Test func secondTurnSeesFirstTurnAnswerButNotThinking() async throws {
        let engine = MockEngine(configuration: .instant)
        let viewModel = makeViewModel(engine: engine)
        viewModel.settings.thinkingEnabled = true
        viewModel.settings.systemPrompt = "Be brief."
        try await viewModel.loadModel(spec)

        #expect(await viewModel.send("Pick a number"))
        let first = viewModel.messages[1]
        #expect(first.text == "27")
        #expect(first.thinking.contains("The user wrote"))
        #expect(first.isThinkingUnterminated == false)

        #expect(await viewModel.send("Now double it"))
        #expect(viewModel.messages.count == 4)
        #expect(viewModel.messages[3].text == "54")

        let history = await engine.lastConversation
        #expect(
            history == [.user("Pick a number"), .assistant("27"), .user("Now double it")])
        let options = try #require(await engine.lastOptions)
        #expect(options.enableThinking == true)
        #expect(options.systemPrompt == "Be brief.")
    }

    @Test func thinkingDurationIsRecordedOnlyForThinkingReplies() async throws {
        let viewModel = makeViewModel()
        try await viewModel.loadModel(spec)

        #expect(await viewModel.send("Pick a number"))
        #expect(viewModel.messages[1].thinkingDuration == nil)

        viewModel.settings.thinkingEnabled = true
        #expect(await viewModel.send("Pick another number"))
        let reply = viewModel.messages[3]
        #expect(!reply.thinking.isEmpty)
        let duration = try #require(reply.thinkingDuration)
        #expect(duration >= 0 && duration < 5)
    }

    @Test func thinkingDurationSurvivesPersistenceAndOldFilesDecode() throws {
        let message = ChatMessage(
            role: .assistant, text: "a", thinking: "t", thinkingDuration: 1.5)
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: data).thinkingDuration == 1.5)

        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["thinkingDuration"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacy)
        #expect(decoded.thinkingDuration == nil)
        #expect(decoded.text == "a")
    }

    @Test func clearModelReturnsToNoModelAndKeepsConversation() async throws {
        let engine = MockEngine(configuration: .instant)
        let persistence = InMemoryConversationStore()
        let viewModel = makeViewModel(engine: engine, persistence: persistence)
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Pick a number"))

        await viewModel.clearModel()
        #expect(viewModel.modelState == .noModel)
        #expect(viewModel.currentModelFit == nil)
        #expect(viewModel.preferredModelID == nil)
        #expect(await engine.loadedModelID() == nil)
        #expect(viewModel.messages.count == 2)
        #expect(try persistence.load()?.modelID == nil)

        #expect(await viewModel.send("Again") == false)
        #expect(viewModel.lastError == ChatError.noModelSelected.localizedDescription)
    }

    @Test func lengthLimitedReplyIsFinishedNotStopped() async throws {
        let viewModel = makeViewModel()
        viewModel.settings.maxTokens = 2
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Tell me something long"))
        let reply = try #require(viewModel.messages.last)
        #expect(reply.state == .done)
        #expect(reply.stats?.stopReason == .maxTokens)
        #expect(reply.stats?.generatedTokens == 2)
        #expect(viewModel.lastError == nil)
    }

    @Test func generationFailureRecordsTheErrorType() async throws {
        struct Boom: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let failing = ChatViewModel(
            engine: FailingEngine(error: InferenceError.generationFailed(wrapping: Boom())),
            store: MockModelStore(downloaded: [spec.id]),
            safety: SafetyMonitor(readThermalState: { .nominal }, observeSystemNotifications: false),
            capability: roomyMemory)
        try await failing.loadModel(spec)
        #expect(await failing.send("Hi"))
        guard case .failed(let message) = failing.messages.last?.state else {
            Issue.record("expected failed, got \(String(describing: failing.messages.last?.state))")
            return
        }
        #expect(message.contains("boom"))
        #expect(failing.lastErrorType?.hasSuffix("Boom") == true)
    }

    @Test func regenerateReplacesLastReply() async throws {
        let engine = MockEngine(configuration: .instant)
        let viewModel = makeViewModel(engine: engine)
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Pick a number"))
        let firstID = viewModel.messages[1].id
        #expect(await viewModel.regenerate())
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages[1].id != firstID)
        #expect(await engine.generationCount == 2)
        #expect(await engine.lastConversation == [.user("Pick a number")])
    }

    @Test func persistenceRoundTrip() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "LLMCoreTests-\(UUID().uuidString)/current.json")
        let persistence = FileConversationStore(fileURL: file)
        let viewModel = makeViewModel(persistence: persistence)
        viewModel.settings.systemPrompt = "Persist me"
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Pick a number"))
        #expect(await viewModel.send("Double it"))

        let restored = makeViewModel(persistence: persistence)
        restored.restore()
        #expect(restored.messages == viewModel.messages)
        #expect(restored.settings.systemPrompt == "Persist me")
        #expect(restored.preferredModelID == spec.id)
        #expect(restored.conversationID == viewModel.conversationID)

        await restored.newConversation()
        let again = makeViewModel(persistence: persistence)
        again.restore()
        #expect(again.messages.isEmpty)
    }

    @Test func streamingMessageIsMarkedStoppedOnRestore() throws {
        let streaming = ChatMessage(role: .assistant, text: "partial", state: .streaming)
        let persistence = InMemoryConversationStore(
            snapshot: ConversationSnapshot(
                id: UUID(), modelID: spec.id, settings: ChatSettings(),
                messages: [ChatMessage(role: .user, text: "q"), streaming], updatedAt: Date()))
        let viewModel = makeViewModel(persistence: persistence)
        viewModel.restore()
        #expect(viewModel.messages.last?.state == .stopped)
        #expect(viewModel.messages.last?.text == "partial")
    }

    @Test func criticalThermalStateStopsAndBlocks() async throws {
        let gate = TokenGate()
        var configuration = MockEngine.Configuration.instant
        configuration.gate = gate
        let safety = SafetyMonitor(readThermalState: { .nominal }, observeSystemNotifications: false)
        let viewModel = makeViewModel(
            engine: MockEngine(configuration: configuration), safety: safety)
        try await viewModel.loadModel(spec)

        let sending = Task { await viewModel.send("Long answer please") }
        gate.release(2)
        try await waitUntil { (viewModel.live?.fragments ?? 0) == 2 }

        safety.update(.serious)
        #expect(safety.isThermalWarning)
        #expect(viewModel.isGenerating, "serious only warns")

        safety.update(.critical)
        _ = await sending.value
        #expect(viewModel.messages.last?.state == .stopped)
        #expect(viewModel.lastError == ChatError.deviceTooHot.localizedDescription)

        gate.open()
        #expect(await viewModel.send("Again") == false)
        #expect(viewModel.lastError == ChatError.deviceTooHot.localizedDescription)

        safety.update(.fair)
        #expect(await viewModel.send("Again"))
    }

    @Test func leavingForegroundStopsAndRefuses() async throws {
        let gate = TokenGate()
        var configuration = MockEngine.Configuration.instant
        configuration.gate = gate
        let engine = MockEngine(configuration: configuration)
        let viewModel = makeViewModel(engine: engine)
        try await viewModel.loadModel(spec)

        let sending = Task { await viewModel.send("Tell me a story") }
        gate.release(1)
        try await waitUntil { (viewModel.live?.fragments ?? 0) == 1 }

        await viewModel.handleLifecycle(.inactive)
        _ = await sending.value
        #expect(viewModel.messages.last?.state == .stopped)
        #expect(viewModel.isGenerating == false)

        await viewModel.handleLifecycle(.background)
        #expect(await viewModel.send("Hi") == false)
        #expect(viewModel.lastError == ChatError.appInBackground.localizedDescription)

        await viewModel.handleLifecycle(.active)
        gate.open()
        #expect(await viewModel.send("Hi"))
    }

    @Test func memoryWarningUnloadsIdleModelAndNextSendReloads() async throws {
        let engine = MockEngine(configuration: .instant)
        let viewModel = makeViewModel(engine: engine)
        try await viewModel.loadModel(spec)
        await viewModel.handleMemoryWarning()
        #expect(viewModel.modelState == .unloaded(spec))
        #expect(await engine.loadedModelID() == nil)
        #expect(await engine.releaseCount == 1)

        #expect(await viewModel.send("Pick a number"))
        #expect(viewModel.modelState == .ready(spec))
        #expect(viewModel.messages.last?.text == "27")
    }

    @Test func memoryWarningDuringGenerationKeepsModel() async throws {
        let gate = TokenGate()
        var configuration = MockEngine.Configuration.instant
        configuration.gate = gate
        let engine = MockEngine(configuration: configuration)
        let viewModel = makeViewModel(engine: engine)
        try await viewModel.loadModel(spec)
        let sending = Task { await viewModel.send("Hi") }
        try await waitUntil { viewModel.isGenerating && viewModel.messages.count == 2 }
        await viewModel.handleMemoryWarning()
        #expect(viewModel.modelState == .ready(spec))
        gate.open()
        _ = await sending.value
        #expect(viewModel.messages.last?.state == .done)
    }

    @Test func tooLargeModelIsRefused() async {
        let tiny = DeviceCapability(measure: {
            MemorySnapshot(physicalMemoryBytes: 2 << 30, footprintBytes: 0, availableBytes: 64 << 20)
        })
        let viewModel = makeViewModel(capability: tiny)
        guard case .tooLarge = viewModel.memoryFit(for: spec) else {
            Issue.record("expected tooLarge")
            return
        }
        await #expect(throws: ChatError.self) {
            try await viewModel.loadModel(spec)
        }
        guard case .failed = viewModel.modelState else {
            Issue.record("expected failed state, got \(viewModel.modelState)")
            return
        }
        #expect(viewModel.lastError?.contains(spec.displayName) == true)
    }

    @Test func notDownloadedModelIsRefused() async {
        let viewModel = makeViewModel()
        await #expect(throws: ChatError.modelNotDownloaded(ModelCatalog.qwen3_4B.displayName)) {
            try await viewModel.loadModel(ModelCatalog.qwen3_4B)
        }
    }

    @Test func engineFailureMarksMessageFailed() async throws {
        var configuration = MockEngine.Configuration.instant
        configuration.loadFailure = "boom"
        let viewModel = makeViewModel(engine: MockEngine(configuration: configuration))
        await #expect(throws: (any Error).self) { try await viewModel.loadModel(spec) }
        guard case .failed(_, let message) = viewModel.modelState else {
            Issue.record("expected failed")
            return
        }
        #expect(message.contains("boom"))
    }

    @Test func busyWhileGenerating() async throws {
        let gate = TokenGate()
        var configuration = MockEngine.Configuration.instant
        configuration.gate = gate
        let viewModel = makeViewModel(engine: MockEngine(configuration: configuration))
        try await viewModel.loadModel(spec)
        let sending = Task { await viewModel.send("First") }
        try await waitUntil { viewModel.isGenerating }
        #expect(await viewModel.send("Second") == false)
        #expect(viewModel.lastError == ChatError.busy.localizedDescription)
        gate.open()
        _ = await sending.value
        #expect(viewModel.messages.count == 2)
    }
}

@Suite("Engine contract (MockEngine)")
struct EngineContractTests {
    let spec = ModelCatalog.qwen3_0_6B

    @Test func generateWithoutModelThrows() async {
        let engine = MockEngine(configuration: .instant)
        await #expect(throws: InferenceError.noModelLoaded) {
            for try await _ in engine.generate([.user("hi")], options: GenerationOptions()) {}
        }
    }

    @Test func consumerCancellationStopsPromptlyAndEngineIsReusable() async throws {
        let gate = TokenGate()
        var configuration = MockEngine.Configuration.instant
        configuration.gate = gate
        let engine = MockEngine(configuration: configuration)
        try await engine.load(spec, from: URL(filePath: "/tmp"), progress: { _ in })

        let consumer = Task {
            var texts = 0
            for try await event in engine.generate([.user("hi")], options: GenerationOptions()) {
                if case .text = event { texts += 1 }
            }
            return texts
        }
        gate.release(2)
        while gate.waitingCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        consumer.cancel()
        _ = try? await consumer.value
        await engine.waitUntilIdle()

        gate.open()
        var finished: GenerationStats?
        for try await event in engine.generate([.user("number?")], options: GenerationOptions()) {
            if case .finished(let stats) = event { finished = stats }
        }
        #expect(finished?.stopReason == .endOfSequence)
    }

    @Test func stopGenerationDeliversCancelledStats() async throws {
        let gate = TokenGate()
        var configuration = MockEngine.Configuration.instant
        configuration.gate = gate
        let engine = MockEngine(configuration: configuration)
        try await engine.load(spec, from: URL(filePath: "/tmp"), progress: { _ in })

        let consumer = Task {
            var last: GenerationStats?
            for try await event in engine.generate([.user("hi")], options: GenerationOptions()) {
                if case .finished(let stats) = event { last = stats }
            }
            return last
        }
        gate.release(1)
        while gate.waitingCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        await engine.stopGeneration()
        let stats = try await consumer.value
        #expect(stats?.stopReason == .cancelled)
        #expect(stats?.generatedTokens == 1)
    }

    @Test func newGenerationCancelsPrevious() async throws {
        let gate = TokenGate()
        var configuration = MockEngine.Configuration.instant
        configuration.gate = gate
        let engine = MockEngine(configuration: configuration)
        try await engine.load(spec, from: URL(filePath: "/tmp"), progress: { _ in })

        let first = Task {
            var reason: StopReason?
            for try await event in engine.generate([.user("a")], options: GenerationOptions()) {
                if case .finished(let stats) = event { reason = stats.stopReason }
            }
            return reason
        }
        while gate.waitingCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        gate.open()
        var secondReason: StopReason?
        for try await event in engine.generate([.user("b")], options: GenerationOptions()) {
            if case .finished(let stats) = event { secondReason = stats.stopReason }
        }
        #expect(secondReason == .endOfSequence)
        let firstReason = try await first.value
        #expect(firstReason == .cancelled || firstReason == .endOfSequence)
    }

    @Test func maxTokensTruncates() async throws {
        let engine = MockEngine(configuration: .instant)
        try await engine.load(spec, from: URL(filePath: "/tmp"), progress: { _ in })
        var options = GenerationOptions()
        options.maxTokens = 2
        var stats: GenerationStats?
        var texts = 0
        for try await event in engine.generate([.user("hi")], options: options) {
            if case .text = event { texts += 1 }
            if case .finished(let value) = event { stats = value }
        }
        #expect(texts == 2)
        #expect(stats?.stopReason == .maxTokens)
    }

    @Test func statsAreJSONSafe() throws {
        let stats = GenerationStats(
            promptTokens: 1, promptTokensPerSecond: .infinity, generatedTokens: 0,
            tokensPerSecond: .nan, timeToFirstToken: nil, totalTime: 0, stopReason: .cancelled,
            droppedMessages: 0)
        let data = try JSONEncoder().encode(stats)
        #expect(data.isEmpty == false)
    }
}

/// An engine whose generations always fail with `error` (after loading normally).
final class FailingEngine: InferenceEngine {
    let error: InferenceError
    init(error: InferenceError) { self.error = error }
    func loadedModelID() async -> String? { nil }
    func load(_ spec: ModelSpec, from directory: URL, progress: @escaping @Sendable (Double?) -> Void)
        async throws
    {}
    func unload() async {}
    func generate(_ conversation: [ChatTurn], options: GenerationOptions)
        -> AsyncThrowingStream<GenerationEvent, Error>
    {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
    func stopGeneration() async {}
    func waitUntilIdle() async {}
    func releaseCachedMemory() async {}
}

import Foundation
import Testing

@testable import LLMCore

/// Replies that end inside a `<think>` block that never closes
/// (``ChatMessage/promoteUnterminatedThinkingIfNeeded()``). On the device, SmolLM3 3B with
/// thinking on wrote its reasoning and the whole answer inside the block and stopped at end of
/// sequence without `</think>`, which used to leave an empty answer.
@MainActor
@Suite("Unterminated thinking")
struct UnterminatedThinkingTests {
    let spec = ModelCatalog.qwen3_0_6B
    let roomyMemory = DeviceCapability(measure: {
        MemorySnapshot(
            physicalMemoryBytes: 12 << 30, footprintBytes: 100 << 20, availableBytes: 6 << 30)
    })

    private func makeViewModel(
        responder: @escaping @Sendable ([ChatTurn], GenerationOptions) -> String,
        gate: TokenGate? = nil
    ) -> (ChatViewModel, MockEngine) {
        var configuration = MockEngine.Configuration.instant
        configuration.responder = responder
        configuration.gate = gate
        let engine = MockEngine(configuration: configuration)
        let viewModel = ChatViewModel(
            engine: engine,
            store: MockModelStore(downloaded: [spec.id]),
            safety: SafetyMonitor(readThermalState: { .nominal }, observeSystemNotifications: false),
            capability: roomyMemory)
        return (viewModel, engine)
    }

    // MARK: - Through ChatViewModel (MockEngine)

    /// Case 1: end of sequence inside an unclosed block, no answer → the text becomes the answer.
    @Test func unclosedThinkingAtEndOfSequenceBecomesTheAnswer() async throws {
        let reply =
            "<think>\nThe user wants a short explanation. Rainbows form when sunlight is refracted in raindrops."
        let (viewModel, engine) = makeViewModel(responder: { _, _ in reply })
        viewModel.settings.thinkingEnabled = true
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Explain rainbows"))

        let message = try #require(viewModel.messages.last)
        #expect(message.role == .assistant)
        #expect(message.state == .done)
        #expect(message.stats?.stopReason == .endOfSequence)
        #expect(message.text.hasPrefix("The user wants a short explanation."))
        #expect(message.text.hasSuffix("refracted in raindrops."))
        #expect(message.thinking.isEmpty)
        #expect(message.isThinkingUnterminated)
        #expect(message.thinkingPromoted == true)
        #expect(message.isThinkingPromoted)
        #expect(message.thinkingDuration == nil)
        #expect(viewModel.lastError == nil)

        // The next turn sends the promoted text back as the assistant's answer.
        #expect(await viewModel.send("Shorter please"))
        let history = await engine.lastConversation
        #expect(
            history == [
                .user("Explain rainbows"), .assistant(message.text), .user("Shorter please"),
            ])
    }

    /// Case 2: the token limit is reached while thinking → stays thinking, finished, not promoted.
    @Test func lengthLimitWhileThinkingKeepsTheThinking() async throws {
        let (viewModel, _) = makeViewModel(responder: { _, _ in
            "<think>\nLet me work through this step by step before answering the question."
        })
        viewModel.settings.thinkingEnabled = true
        viewModel.settings.maxTokens = 5
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Explain rainbows"))

        let message = try #require(viewModel.messages.last)
        #expect(message.state == .done)
        #expect(message.stats?.stopReason == .maxTokens)
        #expect(message.stats?.generatedTokens == 5)
        #expect(message.text.isEmpty)
        #expect(message.thinking.isEmpty == false)
        #expect(message.isThinkingUnterminated)
        #expect(message.thinkingPromoted == nil)
        #expect(message.isThinkingPromoted == false)
        #expect(message.thinkingDuration != nil)
        #expect(viewModel.lastError == nil)
    }

    /// Case 3: Stop while thinking → `.stopped` with the partial thinking, not promoted.
    @Test func stopWhileThinkingKeepsTheThinking() async throws {
        let gate = TokenGate()
        let (viewModel, _) = makeViewModel(
            responder: { _, _ in "<think>\nLet me work through this step by step before answering." },
            gate: gate)
        viewModel.settings.thinkingEnabled = true
        try await viewModel.loadModel(spec)

        let sending = Task { await viewModel.send("Explain rainbows") }
        gate.release(4)
        try await waitUntil { (viewModel.live?.fragments ?? 0) == 4 }
        #expect(viewModel.messages.last?.thinking.isEmpty == false)

        await viewModel.stop()
        _ = await sending.value

        let message = try #require(viewModel.messages.last)
        #expect(message.state == .stopped)
        #expect(message.stats?.stopReason == .cancelled)
        #expect(message.text.isEmpty)
        #expect(message.thinking.isEmpty == false)
        #expect(message.isThinkingUnterminated)
        #expect(message.thinkingPromoted == nil)
        gate.open()
    }

    /// A normal reply (closed block, then an answer) is untouched.
    @Test func closedThinkingWithAnswerIsUntouched() async throws {
        let (viewModel, _) = makeViewModel(responder: MockEngine.defaultResponse)
        viewModel.settings.thinkingEnabled = true
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Pick a number"))

        let message = try #require(viewModel.messages.last)
        #expect(message.state == .done)
        #expect(message.text == "27")
        #expect(message.thinking.contains("The user wrote"))
        #expect(message.isThinkingUnterminated == false)
        #expect(message.thinkingPromoted == nil)
        #expect(message.thinkingDuration != nil)
    }

    /// A closed block with no answer after it is not promoted (the model did close it).
    @Test func closedThinkingWithoutAnswerIsNotPromoted() async throws {
        let (viewModel, _) = makeViewModel(responder: { _, _ in
            "<think>\nOnly reasoning here.\n</think>\n"
        })
        viewModel.settings.thinkingEnabled = true
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Explain rainbows"))

        let message = try #require(viewModel.messages.last)
        #expect(message.state == .done)
        #expect(message.stats?.stopReason == .endOfSequence)
        #expect(message.text.isEmpty)
        #expect(message.thinking.isEmpty == false)
        #expect(message.isThinkingUnterminated == false)
        #expect(message.thinkingPromoted == nil)
    }

    /// An unclosed block with only whitespace in it leaves nothing to promote.
    @Test func whitespaceOnlyUnclosedThinkingIsNotPromoted() async throws {
        let (viewModel, _) = makeViewModel(responder: { _, _ in "<think>\n  \n" })
        viewModel.settings.thinkingEnabled = true
        try await viewModel.loadModel(spec)
        #expect(await viewModel.send("Explain rainbows"))

        let message = try #require(viewModel.messages.last)
        #expect(message.state == .done)
        #expect(message.text.isEmpty)
        #expect(message.thinking.isEmpty)
        #expect(message.isThinkingUnterminated)
        #expect(message.thinkingPromoted == nil)
    }

    // MARK: - The rule itself

    @Test func promotionRuleAppliesOnlyToFinishedEndOfSequenceReplies() {
        func assistant(
            state: ChatMessage.State, stop: StopReason?, text: String = "",
            thinking: String = "reasoning and answer", unterminated: Bool = true
        ) -> ChatMessage {
            ChatMessage(
                role: .assistant, text: text, thinking: thinking,
                isThinkingUnterminated: unterminated, thinkingDuration: 2, state: state,
                stats: stop.map {
                    GenerationStats(
                        promptTokens: 10, promptTokensPerSecond: 100, generatedTokens: 20,
                        tokensPerSecond: 50, timeToFirstToken: 0.1, totalTime: 0.5,
                        stopReason: $0, droppedMessages: 0)
                })
        }

        // Mutating calls stay outside `#expect`, which captures its operands immutably.
        var promoted = assistant(state: .done, stop: .endOfSequence, text: " \n")
        let didPromote = promoted.promoteUnterminatedThinkingIfNeeded()
        #expect(didPromote)
        #expect(promoted.text == "reasoning and answer")
        #expect(promoted.thinking.isEmpty)
        #expect(promoted.thinkingDuration == nil)
        #expect(promoted.isThinkingUnterminated)
        #expect(promoted.thinkingPromoted == true)
        #expect(promoted.state == .done)
        // Applying it again changes nothing.
        let once = promoted
        let promotedAgain = promoted.promoteUnterminatedThinkingIfNeeded()
        #expect(promotedAgain == false)
        #expect(promoted == once)

        let untouched: [ChatMessage] = [
            assistant(state: .done, stop: .maxTokens),
            assistant(state: .stopped, stop: .cancelled),
            assistant(state: .stopped, stop: .endOfSequence),
            assistant(state: .failed("boom"), stop: nil),
            assistant(state: .streaming, stop: nil),
            assistant(state: .done, stop: nil),
            assistant(state: .done, stop: .endOfSequence, text: "The answer."),
            assistant(state: .done, stop: .endOfSequence, unterminated: false),
            assistant(state: .done, stop: .endOfSequence, thinking: "  \n"),
            ChatMessage(role: .user, text: "", thinking: "x", isThinkingUnterminated: true),
        ]
        for original in untouched {
            var copy = original
            let changed = copy.promoteUnterminatedThinkingIfNeeded()
            #expect(changed == false, "\(original)")
            #expect(copy == original)
        }
    }

    @Test func thinkingPromotedSurvivesPersistenceAndOldFilesDecode() throws {
        let message = ChatMessage(
            role: .assistant, text: "a", isThinkingUnterminated: true, thinkingPromoted: true)
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: data).isThinkingPromoted)

        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedFlag = object["thinkingPromoted"] as? Bool
        #expect(encodedFlag == true)
        object["thinkingPromoted"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacy)
        #expect(decoded.thinkingPromoted == nil)
        #expect(decoded.isThinkingPromoted == false)
        #expect(decoded.isThinkingUnterminated)
        #expect(decoded.text == "a")
    }
}

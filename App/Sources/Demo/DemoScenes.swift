#if DEBUG

    import Foundation
    import LLMCore
    import Observation
    import Synchronization

    /// Seeded app states for screenshots and design review (DEBUG builds only).
    ///
    /// Launch with `LLM_UI_DEMO=<scene>` (in the simulator: `SIMCTL_CHILD_LLM_UI_DEMO=<scene>`).
    /// Every scene uses mock models and an in-memory conversation, so it never touches the
    /// user's saved chat. Language and appearance are set from outside (`-AppleLanguages`,
    /// `xcrun simctl ui <device> appearance`).
    enum DemoScene: String, CaseIterable {
        /// First run: nothing downloaded.
        case onboarding
        /// A finished two-turn conversation (thinking block, code block, stats).
        case chat
        /// A reply streaming, with the live readout.
        case streaming
        /// The model list in mixed states.
        case models
        /// The settings sheet over the chat.
        case settings
        /// The settings sheet scrolled to About and Device.
        case about
        /// Generation paused because the device is too hot.
        case thermal
        /// Streaming while the device is hot (serious): the readout carries a warning chip.
        case hot
        /// Model loaded, no messages yet (suggested prompts).
        case ready

        static var requested: DemoScene? {
            ProcessInfo.processInfo.environment["LLM_UI_DEMO"].flatMap(DemoScene.init(rawValue:))
        }

        @MainActor
        static func makeEnvironment(for scene: DemoScene) -> AppEnvironment {
            DemoBuilder(scene: scene).build()
        }
    }

    @MainActor
    private struct DemoBuilder {
        let scene: DemoScene

        private let active = ModelCatalog.qwen3_1_7B

        func build() -> AppEnvironment {
            let safety = SafetyMonitor(
                readThermalState: { [scene] in
                    switch scene {
                    case .thermal: .critical
                    case .hot: .serious
                    default: .nominal
                    }
                },
                observeSystemNotifications: false)
            let store = DemoModelStore(catalog: ModelCatalog.presets)
            let gate = TokenGate()
            var configuration = MockEngine.Configuration(
                tokenDelay: .milliseconds(28), promptDelay: .milliseconds(340),
                loadDelay: .zero, responder: { _, _ in DemoContent.streamingReply })
            if scene == .streaming || scene == .hot { configuration.gate = gate }
            let engine = MockEngine(configuration: configuration)

            let snapshot = ConversationSnapshot(
                id: UUID(), modelID: active.id, settings: ChatSettings(thinkingEnabled: true),
                messages: messages(), updatedAt: Date())
            // Memory as an 8 GB iPhone would report it: lots free before a model is loaded,
            // about 1.25 GB left once it is.
            let memory = Mutex(Self.idleMemory)
            let chat = ChatViewModel(
                engine: engine, store: store, safety: safety,
                capability: DeviceCapability(measure: { memory.withLock { $0 } }),
                persistence: InMemoryConversationStore(snapshot: snapshot))
            chat.restore()

            switch scene {
            case .onboarding:
                break
            case .models:
                store.set(.downloaded(bytesOnDisk: active.downloadBytes), for: active)
                store.set(.downloaded(bytesOnDisk: ModelCatalog.qwen3_0_6B.downloadBytes), for: ModelCatalog.qwen3_0_6B)
                if let downloading = ModelCatalog.presets.first(where: { $0.id.contains("smollm") })
                    ?? ModelCatalog.presets.first(where: { $0.id != active.id && $0.id != ModelCatalog.qwen3_0_6B.id })
                {
                    let received = Int64(Double(downloading.downloadBytes) * 0.42)
                    store.set(
                        .downloading(progress: 0.42, bytesReceived: received, bytesTotal: downloading.downloadBytes),
                        for: downloading)
                }
            default:
                store.set(.downloaded(bytesOnDisk: active.downloadBytes), for: active)
            }

            let environment = AppEnvironment(
                store: store, chat: chat, safety: safety, usesMock: true,
                loadsPreferredModelAutomatically: false)
            environment.demoScene = scene
            switch scene {
            case .models: environment.sheet = .models
            case .settings, .about: environment.sheet = .settings
            default: break
            }

            if scene != .onboarding {
                let active = self.active
                Task { @MainActor in
                    // The scene starts inactive; loading and sending need the app to be active.
                    for _ in 0..<50 where chat.lifecycle != .active {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    try? await chat.loadModel(active)
                    memory.withLock { $0 = Self.loadedMemory }
                    if scene == .streaming || scene == .hot {
                        Self.stream(chat: chat, gate: gate)
                    }
                }
            }
            return environment
        }

        private func messages() -> [ChatMessage] {
            switch scene {
            case .onboarding, .ready: []
            case .streaming, .hot: DemoContent.firstTurn
            case .chat, .models, .settings, .about: DemoContent.firstTurn + DemoContent.secondTurn
            case .thermal: DemoContent.firstTurn + DemoContent.stoppedTurn
            }
        }

        /// Sends the second question and lets about a second of tokens through, then holds the
        /// stream so the screenshot shows a reply mid-generation with the live readout. The pace
        /// (~10 ms per token) matches Qwen3 1.7B on a recent Pro iPhone (~100 tok/s).
        private static func stream(chat: ChatViewModel, gate: TokenGate) {
            Task { @MainActor in
                _ = await chat.send(DemoContent.streamingQuestion)
            }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                // Uneven spacing, like a real decoder, so the rate trace has some texture. Sleeps
                // overshoot by ~2 ms in the simulator, so these land near 95–100 tok/s on screen.
                let pattern = [7, 9, 8, 10, 7, 8, 11, 8, 9, 7, 10, 8]
                // Stop mid-way through the code block (the Chinese reply is shorter in fragments).
                let count = DemoContent.isChinese ? 72 : 118
                // The longer English reply re-renders more Markdown per token; pace it a little
                // faster so both languages show a similar rate.
                let shorten = DemoContent.isChinese ? 0 : 1
                for index in 0..<count {
                    gate.release(1)
                    try? await Task.sleep(
                        for: .milliseconds(pattern[index % pattern.count] - shorten))
                }
            }
        }

        nonisolated private static let idleMemory = MemorySnapshot(
            physicalMemoryBytes: 8 << 30, footprintBytes: 160 << 20, availableBytes: 3_350_000_000)
        nonisolated private static let loadedMemory = MemorySnapshot(
            physicalMemoryBytes: 8 << 30, footprintBytes: 2_230_000_000,
            availableBytes: 1_250_000_000)
    }

    /// A ``ModelStore`` whose states are set directly (frozen progress for screenshots).
    /// Downloads started from the UI still complete, over about three seconds.
    @Observable
    @MainActor
    final class DemoModelStore: ModelStore {
        let catalog: [ModelSpec]
        private(set) var states: [String: ModelInstallState] = [:]
        @ObservationIgnored private var tasks: [String: Task<Void, Error>] = [:]

        init(catalog: [ModelSpec]) {
            self.catalog = catalog
        }

        func set(_ state: ModelInstallState, for spec: ModelSpec) {
            states[spec.id] = state
        }

        func state(for spec: ModelSpec) -> ModelInstallState {
            states[spec.id] ?? .notDownloaded
        }

        func download(_ spec: ModelSpec) async throws {
            if let task = tasks[spec.id] { return try await task.value }
            let task = Task { @MainActor [weak self] in
                for step in 1...30 {
                    try await Task.sleep(for: .milliseconds(100))
                    let fraction = Double(step) / 30
                    self?.states[spec.id] = .downloading(
                        progress: fraction,
                        bytesReceived: Int64(Double(spec.downloadBytes) * fraction),
                        bytesTotal: spec.downloadBytes)
                }
            }
            tasks[spec.id] = task
            states[spec.id] = .downloading(progress: 0, bytesReceived: 0, bytesTotal: spec.downloadBytes)
            defer { tasks[spec.id] = nil }
            do {
                try await task.value
                states[spec.id] = .downloaded(bytesOnDisk: spec.downloadBytes)
            } catch {
                states[spec.id] = .notDownloaded
                throw error
            }
        }

        func cancelDownload(_ spec: ModelSpec) {
            tasks[spec.id]?.cancel()
            if tasks[spec.id] == nil, state(for: spec).isDownloading {
                states[spec.id] = .notDownloaded
            }
        }

        func delete(_ spec: ModelSpec) async throws {
            tasks[spec.id]?.cancel()
            states[spec.id] = .notDownloaded
        }

        func localDirectory(for spec: ModelSpec) -> URL? {
            state(for: spec).isDownloaded
                ? FileManager.default.temporaryDirectory.appending(path: "demo-models/\(spec.id)")
                : nil
        }

        var totalBytesOnDisk: Int64 {
            catalog.reduce(0) { total, spec in
                if case .downloaded(let bytes) = state(for: spec) { return total + bytes }
                return total
            }
        }

        func availableDiskBytes() -> Int64? { 41_800_000_000 }
    }

    /// Conversation content for the demo scenes. It plays the user's own text, so it follows the
    /// launch language (English, or Chinese for zh-Hans screenshots) instead of the String Catalog.
    enum DemoContent {
        static var isChinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }

        private static let codeBlock = """
            ```swift
            func reverseWords(_ sentence: String) -> String {
                sentence
                    .split(whereSeparator: \\.isWhitespace)
                    .reversed()
                    .joined(separator: " ")
            }
            ```
            """

        static var firstTurn: [ChatMessage] {
            [
                ChatMessage(
                    role: .user,
                    text: isChinese ? "你在设备上运行，具体是什么意思？" : "What does it mean that you run on-device?"),
                ChatMessage(
                    role: .assistant,
                    text: isChinese
                        ? """
                        意思是我完全在这台 iPhone 上运行：模型权重存放在 App 里，每一个 token 都由手机自己的 GPU 算出来。

                        - **私密**：你输入的内容不会发送到任何服务器。
                        - **离线**：开着飞行模式也能用。
                        - **坦诚**：我是个小模型，难免出错，重要的事请再核实。
                        """
                        : """
                        It means I run entirely on this iPhone. The model weights sit in the app's storage, and every token is computed by the phone's own GPU.

                        - **Private:** nothing you type is sent to a server.
                        - **Offline:** works in airplane mode.
                        - **Honest limits:** I'm small, so I can be wrong. Double-check anything important.
                        """,
                    state: .done,
                    stats: GenerationStats(
                        promptTokens: 38, promptTokensPerSecond: 412, generatedTokens: 74,
                        tokensPerSecond: 98.4, timeToFirstToken: 0.31, totalTime: 1.06,
                        stopReason: .endOfSequence, droppedMessages: 0),
                    modelID: ModelCatalog.qwen3_1_7B.id),
            ]
        }

        static var streamingQuestion: String {
            isChinese
                ? "写一个 Swift 函数，把句子里的单词顺序反过来。"
                : "Write a Swift function that reverses the words in a sentence."
        }

        private static var thinking: String {
            isChinese
                ? "用户要一个 Swift 函数。最简单的做法：按空白拆分、反转、再用单个空格拼接。顺便提一句连续空格会被合并。保持简短。"
                : "The user wants a Swift function. Simplest approach: split by whitespace, reverse, join with a single space. Mention that repeated spaces collapse. Keep it short."
        }

        private static var answer: String {
            isChinese
                ? """
                按空白拆分，反转数组，再拼回去：

                \(codeBlock)

                `reverseWords("on device models")` 会返回 `"models device on"`。连续的空格会合并成一个，通常正合你意。
                """
                : """
                Split on whitespace, reverse the array, and join it again:

                \(codeBlock)

                `reverseWords("on device models")` returns `"models device on"`. Runs of spaces collapse to one, which is usually what you want.
                """
        }

        static var secondTurn: [ChatMessage] {
            [
                ChatMessage(role: .user, text: streamingQuestion),
                ChatMessage(
                    role: .assistant,
                    text: answer,
                    thinking: thinking,
                    thinkingDuration: 0.5,
                    state: .done,
                    stats: GenerationStats(
                        promptTokens: 156, promptTokensPerSecond: 388, generatedTokens: 212,
                        tokensPerSecond: 96.1, timeToFirstToken: 0.42, totalTime: 2.63,
                        stopReason: .endOfSequence, droppedMessages: 0),
                    modelID: ModelCatalog.qwen3_1_7B.id),
            ]
        }

        static var stoppedTurn: [ChatMessage] {
            [
                ChatMessage(
                    role: .user,
                    text: isChinese
                        ? "用十段话讲讲晶体管的历史。"
                        : "Summarize the history of the transistor in ten paragraphs."),
                ChatMessage(
                    role: .assistant,
                    text: isChinese
                        ? """
                        ## 1947：点接触晶体管

                        在贝尔实验室，威廉·肖克利小组的约翰·巴丁和沃尔特·布拉顿造出了第一个晶体管：两根金触点压在一小块锗片上。它能放大信号，这意味着
                        """
                        : """
                        ## 1947: the point-contact transistor

                        At Bell Labs, John Bardeen and Walter Brattain, working in William Shockley's group, built the first transistor: two gold contacts pressed into a slab of germanium. It could amplify a signal, and it was
                        """,
                    state: .stopped,
                    stats: GenerationStats(
                        promptTokens: 151, promptTokensPerSecond: 395, generatedTokens: 61,
                        tokensPerSecond: 91.2, timeToFirstToken: 0.47, totalTime: 1.14,
                        stopReason: .cancelled, droppedMessages: 0),
                    modelID: ModelCatalog.qwen3_1_7B.id),
            ]
        }

        static var streamingReply: String {
            "<think>\n\(thinking)\n</think>\n\n\(answer)"
        }
    }

#endif

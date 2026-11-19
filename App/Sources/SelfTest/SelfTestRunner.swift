#if SELFTEST

    import Darwin
    import Foundation
    import LLMCore
    import UIKit

    /// On-device self-test, compiled only with the `SELFTEST` condition
    /// (`scripts/build-device.sh --selftest`).
    ///
    /// Launch the app with these environment variables:
    /// - `LLM_SELFTEST=<catalog id>` (required), e.g. `qwen3-0.6b-4bit`
    /// - `LLM_SELFTEST_THINKING=1` — enable thinking for the turns (default off)
    /// - `LLM_SELFTEST_GREEDY=1` — temperature 0 for every turn (argmax decoding), for a
    ///   deterministic comparison with a reference implementation (default: catalog sampling)
    /// - `LLM_SELFTEST_SCREENSHOTS=1` — save `Documents/selftest-turn<N>.png` after each turn
    /// - `LLM_SELFTEST_DELETE_AFTER=1` — after a passing run, unload the model and delete its files
    ///   through the `ModelStore` (reports freed bytes). Failed runs keep the files.
    /// - `LLM_SELFTEST_KEEP_ALIVE=1` — keep running afterwards (default: exit)
    ///
    /// It downloads the model if needed (reporting automatic retries), loads it, and drives three
    /// turns through the same `ChatViewModel` the UI uses, in one conversation: two dependent
    /// short turns (pick a number, double it) and a free-form turn that asks for about 200 words,
    /// so tokens/s and thermal state are measured on a realistic reply (`longTurnCheck`). Every
    /// step prints one line `SELFTEST {json}` to stdout (flushed immediately).
    /// `Documents/selftest-result.json` is written before each risky step (`lastStage`,
    /// `finishedAt: null`), so a jetsam kill during a load still leaves evidence, and again with
    /// the final result. Each turn records the sampling the engine actually used and the reply
    /// text (answer and thinking, each capped at ``SelfTestRunner/textLimit`` characters).
    ///
    /// Failures are recorded as `error {stage, type, message, detail}` in both the stdout
    /// `error`/`done` lines and the result file. `type` is the underlying Swift error type: the
    /// engine keeps it in `InferenceError.generationFailed/loadFailed`, and `ChatViewModel`
    /// exposes it as `lastErrorType` for failed replies.
    ///
    /// A reply that ends at the token limit (`stopReason == maxTokens`) is a finished turn, not
    /// a failure, even if the limit cut it off while thinking (`truncated` in the turn report).
    ///
    /// A reply whose model ended (end of sequence) inside a thinking block it never closed, with
    /// no answer, has that text moved to the answer by `ChatViewModel`
    /// (`ChatMessage.promoteUnterminatedThinkingIfNeeded()`); it counts as answered and is
    /// marked `thinkingPromoted` in the turn report.
    ///
    /// `passed` needs every turn `done` with an answer (or truncated at the token limit);
    /// `dependentTurnCheck` and `longTurnCheck` are informational.
    ///
    /// Exit codes: 0 = passed, 1 = failed, 3 = passed but the requested cleanup failed.
    @MainActor
    final class SelfTestRunner {

        /// The turns, in one conversation. Turn 2 depends on turn 1 (`dependentTurnCheck`).
        /// Turn 3 must yield a long reply; it avoids the words "number" and "double", which
        /// trigger the mock engine's canned answers.
        static let prompts = [
            "Pick one whole number between 11 and 49. Reply with only the number.",
            "Now double the number you just gave me. Reply with only the result.",
            "Explain in about 200 words how a rainbow forms. Write plain prose in two or three paragraphs, without lists or headings.",
        ]
        /// 1-based index of the long turn.
        static let longTurn = 3
        /// The long turn passes `longTurnCheck` with at least this many generated tokens.
        static let longTurnMinimumTokens = 150
        /// Answer and thinking text kept per turn in the report.
        static let textLimit = 4000

        static func runIfRequested(environment: AppEnvironment) async {
            let variables = ProcessInfo.processInfo.environment
            guard let modelID = variables["LLM_SELFTEST"], !modelID.isEmpty else { return }
            let runner = SelfTestRunner(
                environment: environment,
                modelID: modelID,
                thinking: variables["LLM_SELFTEST_THINKING"] == "1",
                greedy: variables["LLM_SELFTEST_GREEDY"] == "1",
                screenshots: variables["LLM_SELFTEST_SCREENSHOTS"] == "1",
                deleteAfter: variables["LLM_SELFTEST_DELETE_AFTER"] == "1",
                keepAlive: variables["LLM_SELFTEST_KEEP_ALIVE"] == "1")
            await runner.run()
        }

        private let environment: AppEnvironment
        private let modelID: String
        private let thinking: Bool
        private let greedy: Bool
        private let screenshots: Bool
        private let deleteAfter: Bool
        private let keepAlive: Bool
        private let started = Date()
        private var result: SelfTestResult
        private var spec: ModelSpec?

        private init(
            environment: AppEnvironment, modelID: String, thinking: Bool, greedy: Bool,
            screenshots: Bool, deleteAfter: Bool, keepAlive: Bool
        ) {
            self.environment = environment
            self.modelID = modelID
            self.thinking = thinking
            self.greedy = greedy
            self.screenshots = screenshots
            self.deleteAfter = deleteAfter
            self.keepAlive = keepAlive
            self.result = SelfTestResult(
                modelID: modelID, startedAt: Date(), thinking: thinking, greedy: greedy,
                deleteAfter: deleteAfter)
        }

        private var chat: ChatViewModel { environment.chat }
        private var store: any ModelStore { environment.store }

        // MARK: - Steps

        private func run() async {
            emit("start", DeviceReport.current(usesMock: environment.usesMockBackend))
            result.device = DeviceReport.current(usesMock: environment.usesMockBackend)

            // The run must happen in the foreground: the chat stops generating when the app
            // leaves it. Keep the screen awake so auto-lock cannot interrupt a long download or
            // reply.
            UIApplication.shared.isIdleTimerDisabled = true
            try? await Task.sleep(for: .seconds(1))
            var waited = 0
            while UIApplication.shared.applicationState != .active || chat.lifecycle != .active,
                waited < 100
            {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard UIApplication.shared.applicationState == .active, chat.lifecycle == .active else {
                return await finish(
                    SelfTestError(
                        stage: "setup", type: "SelfTest.notForeground",
                        message:
                            "App is not in the foreground (device locked?). Unlock the device and relaunch."
                    ))
            }

            guard let spec = store.catalog.first(where: { $0.id == modelID }) else {
                return await finish(
                    SelfTestError(
                        stage: "setup", type: "SelfTest.unknownModel",
                        message: "Unknown model id '\(modelID)'. Known: "
                            + store.catalog.map(\.id).joined(separator: ", ")))
            }
            self.spec = spec
            result.repoID = spec.repoID
            result.revision = spec.revision

            // 1. Download if needed.
            checkpoint("download")
            if !store.state(for: spec).isDownloaded {
                let downloadStart = Date()
                emitFields("download_start", ["bytes": spec.downloadBytes])
                let monitor = Task { @MainActor in await self.reportDownloadProgress(spec) }
                do {
                    try await store.download(spec)
                } catch {
                    monitor.cancel()
                    result.download = DownloadReport(
                        seconds: Date().timeIntervalSince(downloadStart), alreadyPresent: false,
                        bytesOnDisk: nil, retries: downloadRetries(spec),
                        failureMessage: failureMessage(spec))
                    return await finish(SelfTestError(stage: "download", error: error))
                }
                monitor.cancel()
                result.download = DownloadReport(
                    seconds: Date().timeIntervalSince(downloadStart), alreadyPresent: false,
                    bytesOnDisk: bytesOnDisk(spec), retries: downloadRetries(spec))
            } else {
                result.download = DownloadReport(
                    seconds: 0, alreadyPresent: true, bytesOnDisk: bytesOnDisk(spec))
            }
            emit("downloaded", result.download)

            // 2. Load through the view model (memory-fit check included). Greedy = temperature
            //    0, which makes mlx-swift-lm pick ArgMaxSampler (other sampling values unused).
            await chat.newConversation()
            chat.settings = ChatSettings(thinkingEnabled: thinking, temperature: greedy ? 0 : nil)
            let fit = chat.memoryFit(for: spec)
            result.memoryFitBeforeLoad = describe(fit)
            checkpoint("load")
            let loadStart = Date()
            emitFields("load_start", ["memoryFit": describe(fit)])
            do {
                try await chat.loadModel(spec)
            } catch {
                return await finish(SelfTestError(stage: "load", error: error))
            }
            result.load = LoadReport(
                seconds: Date().timeIntervalSince(loadStart), memoryFit: describe(fit),
                memory: MemoryProbe.current(), mlx: MLXRuntimeInfo.snapshot())
            emit("loaded", result.load)
            environment.showsChat = true
            try? await Task.sleep(for: .milliseconds(500))

            // 3. The turns (see `prompts`).
            for (index, prompt) in Self.prompts.enumerated() {
                let stage = "turn \(index + 1)"
                checkpoint(stage)
                emitFields("turn_start", ["turn": index + 1, "prompt": prompt] as [String: any Sendable])
                let sent = await chat.send(prompt)
                guard sent, let reply = chat.messages.last, reply.role == .assistant else {
                    return await finish(
                        SelfTestError(
                            stage: stage, type: "ChatViewModel.send(_:) returned false",
                            message: chat.lastError ?? "unknown"))
                }
                let truncated = reply.stats?.stopReason == .maxTokens
                var turn = TurnReport(
                    turn: index + 1, prompt: prompt,
                    answer: String(reply.text.prefix(Self.textLimit)),
                    answerCharacters: reply.text.count,
                    thinking: reply.thinking.isEmpty
                        ? nil : String(reply.thinking.prefix(Self.textLimit)),
                    thinkingCharacters: reply.thinking.count,
                    thinkingUnterminated: reply.isThinkingUnterminated,
                    thinkingPromoted: reply.isThinkingPromoted,
                    truncated: truncated,
                    state: describe(reply.state), stats: reply.stats,
                    sampling: reply.stats?.sampling,
                    thermalState: environment.safety.thermalLevel.description,
                    memory: MemoryProbe.current(), mlx: MLXRuntimeInfo.snapshot(), screenshot: nil)
                if screenshots {
                    try? await Task.sleep(for: .milliseconds(600))
                    turn.screenshot = captureScreenshot(named: "selftest-turn\(index + 1).png")
                }
                result.turns.append(turn)
                emit("turn", turn)

                switch reply.state {
                case .failed(let message):
                    return await finish(
                        SelfTestError(
                            stage: stage,
                            type: chat.lastErrorType ?? "ChatMessage.State.failed",
                            message: message, detail: chat.lastError))
                case .stopped:
                    return await finish(
                        SelfTestError(
                            stage: stage, type: "ChatMessage.State.stopped",
                            message: "Reply was stopped early (lifecycle or thermal safety).",
                            detail: chat.lastError))
                case .streaming, .done:
                    break
                }
                if reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !truncated {
                    let reason = reply.stats?.stopReason.rawValue ?? "unknown"
                    return await finish(
                        SelfTestError(
                            stage: stage, type: "SelfTest.emptyAnswer",
                            message:
                                "Reply has no answer text (stop reason: \(reason), thinking unterminated: \(reply.isThinkingUnterminated))."
                        ))
                }
            }

            // 4. Check that turn 2 used turn 1 (informational; small models can get it wrong).
            let first = Self.firstInteger(in: result.turns[0].answer)
            let second = Self.firstInteger(in: result.turns[1].answer)
            if let first, let second {
                result.dependentTurnCheck = second == first * 2 ? "pass" : "mismatch"
            } else {
                result.dependentTurnCheck = "unparsable"
            }

            // 5. The long turn must be long enough to measure (informational, like step 4).
            let longTokens = result.turns[Self.longTurn - 1].stats?.generatedTokens ?? 0
            result.longTurnCheck = longTokens >= Self.longTurnMinimumTokens ? "pass" : "short"
            await finish(nil)
        }

        private func reportDownloadProgress(_ spec: ModelSpec) async {
            var lastFraction = -1.0
            var lastEmit = Date.distantPast
            var reportedRetries = 0
            while !Task.isCancelled {
                let retries = downloadRetries(spec) ?? []
                for record in retries.dropFirst(reportedRetries) {
                    emit("download_retry", record)
                }
                reportedRetries = retries.count
                if case .downloading(let fraction, let received, let total) = store.state(for: spec),
                    fraction - lastFraction >= 0.05 || Date().timeIntervalSince(lastEmit) >= 5
                {
                    emitFields(
                        "progress",
                        ["phase": "download", "fraction": fraction, "bytes": received, "total": total]
                            as [String: any Sendable])
                    lastFraction = fraction
                    lastEmit = Date()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        private func finish(_ error: SelfTestError?) async {
            if let error {
                result.error = error
                result.failure = "\(error.stage): \(error.message)"
                emit("error", error)
            }
            result.passed =
                error == nil && result.turns.count == Self.prompts.count
                && result.turns.allSatisfy {
                    $0.state == "done" && (!$0.answer.isEmpty || $0.truncated)
                }

            if deleteAfter {
                result.cleanup = await cleanUp()
                emit("cleanup", result.cleanup)
            }

            result.lastStage = "finished"
            result.finishedAt = Date()
            result.entitlements = EntitlementReport.current()
            result.finalMemory = MemoryProbe.current()
            result.finalThermalState = environment.safety.thermalLevel.description
            writeResultFile()
            emit("done", result)
            UIApplication.shared.isIdleTimerDisabled = false

            if !keepAlive {
                try? await Task.sleep(for: .milliseconds(300))
                let cleanupFailed = result.cleanup?.error != nil
                exit(result.passed ? (cleanupFailed ? 3 : 0) : 1)
            }
        }

        /// Unloads and deletes the tested model after a passing run (`LLM_SELFTEST_DELETE_AFTER`).
        private func cleanUp() async -> CleanupReport {
            var report = CleanupReport(requested: true, deleted: false)
            guard result.passed else {
                report.skippedReason = "Run did not pass; model files kept for inspection."
                return report
            }
            guard let spec else {
                report.skippedReason = "No model selected."
                return report
            }
            await chat.unloadModel()
            report.bytesOnDiskBefore = store.totalBytesOnDisk
            report.freeDiskBytesBefore = store.availableDiskBytes()
            do {
                try await store.delete(spec)
                report.deleted = !store.state(for: spec).isDownloaded
            } catch {
                report.error = SelfTestError(stage: "cleanup", error: error)
            }
            report.bytesOnDiskAfter = store.totalBytesOnDisk
            report.freeDiskBytesAfter = store.availableDiskBytes()
            if let before = report.bytesOnDiskBefore, let after = report.bytesOnDiskAfter {
                report.freedBytes = before - after
            }
            return report
        }

        // MARK: - Output

        /// Writes the in-progress result (`finishedAt: null`) before a step that may crash.
        private func checkpoint(_ stage: String) {
            result.lastStage = stage
            writeResultFile()
        }

        private func writeResultFile() {
            let url = URL.documentsDirectory.appending(path: "selftest-result.json")
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(result).write(to: url, options: .atomic)
                result.resultFile = url.path
            } catch {
                emitFields(
                    "error",
                    ["stage": "report", "type": String(reflecting: type(of: error)),
                     "message": "Could not write result file: \(error.localizedDescription)"])
            }
        }

        private func emit(_ event: String, _ payload: some Encodable) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            var object: [String: Any] = [:]
            if let data = try? encoder.encode(payload),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                object = decoded
            }
            emitObject(event, object)
        }

        private func emitFields(_ event: String, _ payload: [String: any Sendable]) {
            emitObject(event, payload)
        }

        private func emitObject(_ event: String, _ payload: [String: Any]) {
            var object = payload
            object["event"] = event
            object["t"] = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                let json = String(data: data, encoding: .utf8)
            else { return }
            let line = "SELFTEST \(json)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
            fflush(stdout)
        }

        // MARK: - Helpers

        private func captureScreenshot(named name: String) -> String? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard
                let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
                    ?? scenes.first?.windows.first
            else { return nil }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = URL.documentsDirectory.appending(path: name)
            guard let png = image.pngData(), (try? png.write(to: url, options: .atomic)) != nil else {
                return nil
            }
            return url.lastPathComponent
        }

        private func bytesOnDisk(_ spec: ModelSpec) -> Int64? {
            if case .downloaded(let bytes) = store.state(for: spec) { return bytes }
            return nil
        }

        /// Automatic retries of the download (`nil` with the mock store, which has none).
        private func downloadRetries(_ spec: ModelSpec) -> [DownloadRetryRecord]? {
            (store as? LiveModelStore)?.downloadRetries(for: spec)
        }

        /// The message the UI shows for a failed download.
        private func failureMessage(_ spec: ModelSpec) -> String? {
            if case .failed(let message) = store.state(for: spec) { return message }
            return nil
        }

        private func describe(_ fit: MemoryFit) -> String {
            switch fit {
            case .ok: "ok"
            case .tight: "tight"
            case .tooLarge(let reason): "tooLarge: \(reason)"
            }
        }

        private func describe(_ state: ChatMessage.State) -> String {
            switch state {
            case .streaming: "streaming"
            case .done: "done"
            case .stopped: "stopped"
            case .failed: "failed"
            }
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
    }

    // MARK: - Report types

    /// A failure: where it happened, the Swift error type, and its messages.
    struct SelfTestError: Codable {
        var stage: String
        /// Fully qualified Swift type of the error (e.g. `LLMCore.InferenceError`), or a label for
        /// failures that are not Swift errors.
        var type: String
        /// `localizedDescription`.
        var message: String
        /// `String(describing:)` of the error (enum case and payload), or extra context.
        var detail: String?

        init(stage: String, type: String, message: String, detail: String? = nil) {
            self.stage = stage
            self.type = type
            self.message = message
            self.detail = detail
        }

        init(stage: String, error: any Error) {
            self.init(
                stage: stage,
                type: InferenceError.typeName(of: error),
                message: error.localizedDescription,
                detail: String(String(describing: error).prefix(2000)))
        }
    }

    /// Format history: 2 = two turns. 3 = three turns (turn 3 is the long one); adds `greedy`,
    /// `longTurnCheck`, per-turn `sampling`, `answerCharacters` and `thinking` (`answer` is now
    /// capped at `SelfTestRunner.textLimit`), and `download.retries` / `failureMessage`. Later
    /// additions to format 3 are optional keys that older results lack: per-turn
    /// `thinkingPromoted`.
    struct SelfTestResult: Codable {
        var formatVersion = 3
        var modelID: String
        var repoID: String?
        var revision: String?
        var startedAt: Date
        var finishedAt: Date?
        /// Last step started ("download", "load", "turn 1"…"turn 3", "finished"). With
        /// `finishedAt == nil` it tells where a killed run stopped.
        var lastStage = "setup"
        var thinking: Bool
        /// Temperature 0 for every turn (`LLM_SELFTEST_GREEDY`).
        var greedy: Bool
        var deleteAfter: Bool
        var passed = false
        /// Short summary of `error` (kept for older readers).
        var failure: String?
        var error: SelfTestError?
        /// "pass" when turn 2's number is twice turn 1's, otherwise "mismatch"/"unparsable".
        /// Informational: small models can get arithmetic wrong.
        var dependentTurnCheck = "not-run"
        /// "pass" when the long turn generated at least
        /// `SelfTestRunner.longTurnMinimumTokens` tokens, otherwise "short" (its tokens/s is then
        /// less meaningful). Informational; the mock engine's reply is always short.
        var longTurnCheck = "not-run"
        var device: DeviceReport?
        var download: DownloadReport?
        var memoryFitBeforeLoad: String?
        var load: LoadReport?
        var turns: [TurnReport] = []
        var cleanup: CleanupReport?
        var entitlements: EntitlementReport?
        var finalMemory: MemorySnapshot?
        var finalThermalState: String?
        var resultFile: String?

        init(modelID: String, startedAt: Date, thinking: Bool, greedy: Bool, deleteAfter: Bool) {
            self.modelID = modelID
            self.startedAt = startedAt
            self.thinking = thinking
            self.greedy = greedy
            self.deleteAfter = deleteAfter
        }
    }

    struct CleanupReport: Codable {
        var requested: Bool
        var deleted: Bool
        var skippedReason: String?
        var freedBytes: Int64?
        var bytesOnDiskBefore: Int64?
        var bytesOnDiskAfter: Int64?
        var freeDiskBytesBefore: Int64?
        var freeDiskBytesAfter: Int64?
        var error: SelfTestError?
    }

    struct DeviceReport: Codable {
        var machine: String
        var systemVersion: String
        var usesMockBackend: Bool
        var lowPowerMode: Bool
        var thermalState: String
        var memory: MemorySnapshot
        var entitlements: EntitlementReport

        @MainActor static func current(usesMock: Bool) -> DeviceReport {
            var info = utsname()
            uname(&info)
            let machine = withUnsafeBytes(of: info.machine) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return DeviceReport(
                machine: machine,
                systemVersion: UIDevice.current.systemVersion,
                usesMockBackend: usesMock,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ThermalLevel(ProcessInfo.processInfo.thermalState).description,
                memory: MemoryProbe.current(),
                entitlements: EntitlementReport.current())
        }
    }

    struct DownloadReport: Codable {
        var seconds: Double
        var alreadyPresent: Bool
        var bytesOnDisk: Int64?
        /// Automatic retries (`LiveModelStore`); `nil` with the mock store.
        var retries: [DownloadRetryRecord]?
        /// What the UI shows for a failed download.
        var failureMessage: String?
    }

    struct LoadReport: Codable {
        var seconds: Double
        var memoryFit: String
        var memory: MemorySnapshot
        var mlx: MLXRuntimeInfo.Snapshot?
    }

    struct TurnReport: Codable {
        var turn: Int
        var prompt: String
        /// The visible answer (without thinking), capped at `SelfTestRunner.textLimit`.
        var answer: String
        /// Length of the whole answer.
        var answerCharacters: Int
        /// The thinking text, capped like `answer`; `nil` when there was none.
        var thinking: String?
        var thinkingCharacters: Int
        var thinkingUnterminated: Bool
        /// The model ended inside a thinking block it never closed and wrote no answer, so
        /// `ChatViewModel` moved that text to `answer` (`thinking` is then `nil`,
        /// `thinkingUnterminated` stays `true`). Optional key: absent in results written before
        /// it existed (same `formatVersion`).
        var thinkingPromoted: Bool?
        /// The reply ended at the token limit (`stats.stopReason == maxTokens`).
        var truncated: Bool
        var state: String
        var stats: GenerationStats?
        /// Sampling the engine used (also inside `stats`; repeated here for readers).
        var sampling: SamplingRecord?
        var thermalState: String
        var memory: MemorySnapshot
        var mlx: MLXRuntimeInfo.Snapshot?
        var screenshot: String?
    }

#endif

import Foundation
import Testing

@testable import LLMCore

@Suite("Engine helpers")
struct EngineHelpersTests {

    // MARK: Stop reason (mlx-swift-lm 3.31.3 reports `.cancelled` at maxTokens)

    @Test func cancelledAtTheLimitWithoutAStopIsALengthLimit() {
        #expect(
            StopReason.resolved(
                libraryReason: .cancelled, stopRequested: false, generatedTokens: 1024,
                maxTokens: 1024) == .maxTokens)
        // More than the limit can only come from a different counter; still the limit.
        #expect(
            StopReason.resolved(
                libraryReason: .cancelled, stopRequested: false, generatedTokens: 1025,
                maxTokens: 1024) == .maxTokens)
    }

    @Test func requestedStopsStayCancelled() {
        // The user (or a safety monitor, or the consumer going away) stopped it, even if the
        // count happens to equal the limit.
        #expect(
            StopReason.resolved(
                libraryReason: .cancelled, stopRequested: true, generatedTokens: 1024,
                maxTokens: 1024) == .cancelled)
        #expect(
            StopReason.resolved(
                libraryReason: .cancelled, stopRequested: true, generatedTokens: 10,
                maxTokens: 1024) == .cancelled)
    }

    @Test func cancelledBelowTheLimitStaysCancelled() {
        #expect(
            StopReason.resolved(
                libraryReason: .cancelled, stopRequested: false, generatedTokens: 1023,
                maxTokens: 1024) == .cancelled)
    }

    @Test func otherLibraryReasonsPassThrough() {
        for requested in [false, true] {
            #expect(
                StopReason.resolved(
                    libraryReason: .endOfSequence, stopRequested: requested,
                    generatedTokens: 1024, maxTokens: 1024) == .endOfSequence)
            #expect(
                StopReason.resolved(
                    libraryReason: .maxTokens, stopRequested: requested, generatedTokens: 5,
                    maxTokens: 1024) == .maxTokens)
        }
    }

    // MARK: Error type names

    private struct SampleError: Error {}

    @Test func wrappedErrorsKeepTheUnderlyingTypeName() {
        let wrapped = InferenceError.generationFailed(wrapping: SampleError())
        #expect(wrapped.underlyingTypeName?.hasSuffix("SampleError") == true)
        #expect(InferenceError.typeName(of: wrapped) == wrapped.underlyingTypeName)
        #expect(wrapped.localizedDescription.hasPrefix("Generation failed"))

        let load = InferenceError.loadFailed(wrapping: CancellationError())
        #expect(load.underlyingTypeName == "Swift.CancellationError")

        #expect(InferenceError.noModelLoaded.underlyingTypeName == nil)
        #expect(InferenceError.typeName(of: InferenceError.noModelLoaded) == "LLMCore.InferenceError")
        #expect(InferenceError.typeName(of: SampleError()).hasSuffix("SampleError"))
        // Unwrapped messages (older call sites) still work.
        #expect(InferenceError.loadFailed("boom").underlyingTypeName == nil)
    }

    // MARK: User-Agent

    @Test func userAgentComesFromTheBundle() {
        #expect(
            UserAgent.make(infoDictionary: [
                "CFBundleDisplayName": "Pocket LLM", "CFBundleName": "LLMOnIPhone",
                "CFBundleShortVersionString": "0.1.0",
            ]) == "PocketLLM/0.1.0")
        // Renamed app, new version: no code change needed.
        #expect(
            UserAgent.make(infoDictionary: [
                "CFBundleDisplayName": "Tiny Chat!", "CFBundleShortVersionString": "2.3",
            ]) == "TinyChat!/2.3")
    }

    @Test func userAgentFallbacks() {
        // A display name with no token characters falls back to CFBundleName.
        #expect(
            UserAgent.make(infoDictionary: [
                "CFBundleDisplayName": "口袋模型", "CFBundleName": "LLMOnIPhone",
                "CFBundleShortVersionString": "1.0",
            ]) == "LLMOnIPhone/1.0")
        #expect(UserAgent.make(infoDictionary: ["CFBundleName": "App Name"]) == "AppName/0")
        #expect(UserAgent.make(infoDictionary: nil) == "App/0")
        #expect(UserAgent.make(infoDictionary: ["CFBundleShortVersionString": "1 (beta)"]) == "App/1beta")
    }

    // MARK: Sampling record (persisted inside GenerationStats)

    @Test func statsSavedBeforeTheSamplingRecordStillDecode() throws {
        let old = """
            {"promptTokens": 31, "promptTokensPerSecond": 457, "generatedTokens": 2,
             "tokensPerSecond": 89.5, "timeToFirstToken": 0.08, "totalTime": 0.2,
             "stopReason": "endOfSequence", "droppedMessages": 0}
            """
        let stats = try JSONDecoder().decode(GenerationStats.self, from: Data(old.utf8))
        #expect(stats.sampling == nil)
        #expect(stats.generatedTokens == 2)

        var withSampling = stats
        withSampling.sampling = SamplingRecord(
            temperature: 0, topP: 0.8, topK: 20, minP: 0, maxTokens: 1024, seed: 42,
            seedControlsSampling: false, sampler: "ArgMaxSampler")
        let data = try JSONEncoder().encode(withSampling)
        #expect(try JSONDecoder().decode(GenerationStats.self, from: data) == withSampling)
    }

    @Test func mockEngineReportsTheSamplingItWasGiven() async throws {
        let engine = MockEngine(configuration: .instant)
        try await engine.load(ModelCatalog.qwen3_0_6B, from: URL(filePath: "/tmp"), progress: { _ in })
        let options = GenerationOptions(temperature: 0, topP: 0.8, topK: 20, minP: 0.05, maxTokens: 64, seed: 7)
        var finished: GenerationStats?
        for try await event in engine.generate([.user("hi")], options: options) {
            if case .finished(let stats) = event { finished = stats }
        }
        let sampling = try #require(finished?.sampling)
        #expect(sampling.temperature == 0 && sampling.topP == 0.8 && sampling.topK == 20)
        #expect(sampling.minP == 0.05 && sampling.maxTokens == 64 && sampling.seed == 7)
        #expect(sampling.sampler == "mock")
    }
}

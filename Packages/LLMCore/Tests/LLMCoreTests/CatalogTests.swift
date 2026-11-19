import Foundation
import Testing

@testable import LLMCore

@Suite("Catalog")
struct CatalogTests {
    let presets = ModelCatalog.presets

    @Test func idsAreUniqueAndFileSystemSafe() {
        #expect(Set(presets.map(\.id)).count == presets.count)
        for spec in presets {
            #expect(LiveModelStore.isSafeIdentifier(spec.id), "\(spec.id)")
        }
        #expect(LiveModelStore.isSafeIdentifier("../evil") == false)
        #expect(LiveModelStore.isSafeIdentifier("Upper") == false)
    }

    @Test func repoIDsAndRevisions() {
        for spec in presets {
            let parts = spec.repoID.split(separator: "/")
            #expect(parts.count == 2, "\(spec.repoID)")
            // Pinned to a full commit hash.
            #expect(spec.revision.count == 40, "\(spec.id)")
            let isHex = spec.revision.allSatisfy { $0.isHexDigit }
            #expect(isHex, "\(spec.id)")
        }
        #expect(Set(presets.map(\.repoID)).count == presets.count)
    }

    @Test func sizesAreSane() {
        for spec in presets {
            #expect(spec.downloadBytes > 100_000_000, "\(spec.id)")
            #expect(spec.downloadBytes < 10_000_000_000, "\(spec.id)")
            #expect(spec.runtime.kvCacheBytesPerToken > 0)
            #expect(spec.runtime.maxContextTokens >= 4096)
        }
        let sizes = presets.map(\.downloadBytes)
        #expect(sizes == sizes.sorted(), "presets are listed small to large")
    }

    @Test func presetOrderAndIDs() {
        #expect(
            presets.map(\.id) == [
                "qwen3-0.6b-4bit", "qwen3-1.7b-4bit", "smollm3-3b-4bit", "phi-4-mini-4bit",
                "qwen3-4b-4bit",
            ])
    }

    @Test func kvBytesMatchConfigNumbers() {
        // 2 × layers × kv_heads × head_dim × 2 bytes, from each repo's config.json.
        #expect(ModelCatalog.qwen3_0_6B.runtime.kvCacheBytesPerToken == 2 * 28 * 8 * 128 * 2)
        #expect(ModelCatalog.qwen3_1_7B.runtime.kvCacheBytesPerToken == 2 * 28 * 8 * 128 * 2)
        #expect(ModelCatalog.qwen3_4B.runtime.kvCacheBytesPerToken == 2 * 36 * 8 * 128 * 2)
        // SmolLM3: 36 layers, 4 KV heads, 2048 / 16 heads.
        #expect(ModelCatalog.smolLM3_3B.runtime.kvCacheBytesPerToken == 73_728)
        #expect(ModelCatalog.smolLM3_3B.runtime.maxContextTokens == 65_536)
        // Phi-4-mini: 32 layers, 8 KV heads, 3072 / 24 heads.
        #expect(ModelCatalog.phi4Mini.runtime.kvCacheBytesPerToken == 131_072)
        #expect(ModelCatalog.phi4Mini.runtime.maxContextTokens == 131_072)
    }

    @Test func blurbsAreLocalized() {
        for spec in presets {
            let blurb = spec.localizedBlurb
            #expect(blurb != spec.blurbKey, "missing string for \(spec.blurbKey)")
            #expect(blurb.isEmpty == false)
            #expect(spec.englishBlurb?.isEmpty == false, "\(spec.id) needs an English fallback")
        }
        // Keys not yet in the String Catalog fall back to the English text.
        #expect(ModelCatalog.phi4Mini.localizedBlurb == ModelCatalog.phi4Mini.englishBlurb)
    }

    @Test func licensesAndThinking() {
        for spec in presets {
            #expect(["apache-2.0", "mit"].contains(spec.license.id), "\(spec.id)")
            #expect(spec.license.url.scheme == "https")
            // A thinking toggle implies thinking-mode sampling and vice versa.
            #expect(spec.supportsThinkingToggle == (spec.thinkingSampling != nil), "\(spec.id)")
        }
        for spec in presets where spec.family == .qwen3 {
            #expect(spec.license == .apache2)
            #expect(spec.supportsThinkingToggle)
            #expect(spec.extraEOSTokens == ["<|endoftext|>"])
        }

        let smol = ModelCatalog.smolLM3_3B
        #expect(smol.family == .smolLM)
        #expect(smol.license == .apache2)
        #expect(smol.supportsThinkingToggle)
        #expect(smol.extraEOSTokens.isEmpty)

        let phi = ModelCatalog.phi4Mini
        #expect(phi.family == .phi)
        #expect(phi.license.id == "mit")
        #expect(phi.supportsThinkingToggle == false)
        #expect(phi.extraEOSTokens.isEmpty)
    }

    @Test func modelCardSampling() {
        // SmolLM3 card: temperature 0.6, top_p 0.95 (both modes).
        for thinking in [false, true] {
            let options = GenerationOptions.recommended(for: ModelCatalog.smolLM3_3B, thinking: thinking)
            #expect(options.temperature == 0.6)
            #expect(options.topP == 0.95)
            #expect(options.topK == 0)
            #expect(options.enableThinking == thinking)
        }
        // Phi-4-mini card examples: greedy. No thinking switch, so nothing is passed to the
        // template even if the user turned thinking on.
        let phi = ChatSettings(thinkingEnabled: true).options(for: ModelCatalog.phi4Mini)
        #expect(phi.temperature == 0)
        #expect(phi.enableThinking == nil)
        #expect(phi.maxTokens == 1024)
    }

    @Test func everyPresetFitsATypicalProPhoneBudget() {
        // ~6 GiB allowance, recommended thinking context.
        let snapshot = MemorySnapshot(
            physicalMemoryBytes: 12 << 30, footprintBytes: 150 << 20, availableBytes: 6 << 30)
        for spec in presets {
            let context = GenerationOptions.recommended(for: spec, thinking: true).contextTokens
            #expect(
                DeviceCapability.fit(for: spec, contextTokens: context, snapshot: snapshot) == .ok,
                "\(spec.id)")
        }
    }

    @Test func lookupAndRecommendedOptions() {
        #expect(ModelCatalog.spec(id: "qwen3-1.7b-4bit") == ModelCatalog.qwen3_1_7B)
        #expect(ModelCatalog.spec(id: "nope") == nil)

        let spec = ModelCatalog.qwen3_0_6B
        let thinking = GenerationOptions.recommended(for: spec, thinking: true)
        #expect(thinking.enableThinking == true)
        #expect(thinking.temperature == 0.6)
        #expect(thinking.topP == 0.95)
        #expect(thinking.topK == 20)
        let direct = GenerationOptions.recommended(for: spec, thinking: false)
        #expect(direct.enableThinking == false)
        #expect(direct.temperature == 0.7)
        #expect(direct.topP == 0.8)
        #expect(direct.contextTokens == GenerationOptions.defaultPromptTokenBudget + direct.maxTokens)
    }

    @Test func settingsOverrideRecommendedSampling() {
        var settings = ChatSettings(systemPrompt: "  ", thinkingEnabled: true)
        settings.temperature = 0.1
        settings.maxTokens = 64
        let options = settings.options(for: ModelCatalog.qwen3_0_6B)
        #expect(options.systemPrompt == nil, "blank system prompt is omitted")
        #expect(options.temperature == 0.1)
        #expect(options.topP == 0.95)
        #expect(options.maxTokens == 64)
        #expect(options.enableThinking == true)
    }

    @Test func firstRunRecommendation() {
        let small = ModelCatalog.qwen3_0_6B
        let medium = ModelCatalog.qwen3_1_7B
        func pick(_ fits: [String: MemoryFit]) -> ModelSpec? {
            ModelCatalog.recommendedFirstModel(fit: { fits[$0.id] ?? .ok })
        }
        // Qwen3 1.7B whenever it fits comfortably, even if larger models also fit.
        #expect(pick([:]) == medium)
        // Otherwise Qwen3 0.6B, but only when that fits comfortably too.
        #expect(pick([medium.id: .tight]) == small)
        #expect(pick([medium.id: .tooLarge(reason: "x")]) == small)
        // Never a tight or too-large model, and never another family as a fallback.
        #expect(pick([medium.id: .tight, small.id: .tight]) == nil)
        #expect(pick([medium.id: .tooLarge(reason: "x"), small.id: .tooLarge(reason: "x")]) == nil)
        // A catalog without the 1.7B preset falls back to 0.6B.
        #expect(ModelCatalog.recommendedFirstModel(in: [small], fit: { _ in .ok }) == small)
        #expect(ModelCatalog.recommendedFirstModel(in: [], fit: { _ in .ok }) == nil)
    }

    @Test func qwen3_4BBlurbMentionsWarmUpAndNoStaleCount() {
        let blurb = ModelCatalog.qwen3_4B.englishBlurb ?? ""
        #expect(blurb.contains("of the three") == false)
        #expect(blurb.contains("warms up"))
        #expect(ModelCatalog.qwen3_4B.localizedBlurb.contains("warms up"))
    }

    @Test func specIsCodable() throws {
        let data = try JSONEncoder().encode(presets)
        let decoded = try JSONDecoder().decode([ModelSpec].self, from: data)
        #expect(decoded == presets)
    }
}

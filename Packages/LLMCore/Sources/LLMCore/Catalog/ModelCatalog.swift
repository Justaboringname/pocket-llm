import Foundation

/// The built-in list of models.
///
/// Adding a model = adding one `ModelSpec` here. Sizes live only in this file. Blurbs have an
/// English fallback here; translations go into the package's `Localizable.xcstrings` under the
/// same `blurbKey`.
///
/// How the numbers were obtained (2026-11-18), always at the pinned revision:
/// - `downloadBytes`: `https://huggingface.co/api/models/<repo>/revision/<sha>?blobs=true`,
///   summing the `size` of the files matched by ``ModelDownloadPatterns/all`` (what the app
///   actually downloads; README, `.gitattributes`, `merges.txt` and `*.py` are not fetched).
/// - `revision`: the repo commit sha.
/// - `runtime`: from the repo's `config.json` (`num_hidden_layers`, `num_key_value_heads`,
///   `head_dim` or `hidden_size / num_attention_heads`, `max_position_embeddings`).
/// - EOS: mlx-swift-lm stops on `config.json` `eos_token_id` (overridden by
///   `generation_config.json` when present) plus the tokenizer's `eos_token`; `extraEOSTokens`
///   lists only what upstream stops on beyond that.
/// - Sampling: the upstream model card; `maxTokens` is a phone-friendly cap.
///
/// `verifiedOnDevice` notes are comments only (not user-facing state). "Device 2026-11-18" means:
/// downloaded at the pinned revision, loaded and completed the three-turn device self-test in this
/// app on an iPhone 18 Pro Max (iOS 27.2.1, Release, thinking off unless noted; numbers in the
/// README's Performance section). "Static" means the config/weights were checked against the
/// mlx-swift-lm 3.31.3 source and the chat template was rendered with swift-transformers 1.3.0 /
/// swift-jinja 2.3.1 on the Mac (tokenizer only, no inference).
public enum ModelCatalog {

    /// Small to large by download size.
    public static let presets: [ModelSpec] = [
        qwen3_0_6B,
        qwen3_1_7B,
        smolLM3_3B,
        phi4Mini,
        qwen3_4B,
    ]

    /// Look up a preset by its catalog id.
    public static func spec(id: String) -> ModelSpec? {
        presets.first { $0.id == id }
    }

    /// The model to suggest on first run: Qwen3 1.7B when its memory fit is `.ok`, otherwise
    /// Qwen3 0.6B when that fit is `.ok`, otherwise none. A `.tight` or `.tooLarge` model is
    /// never recommended. (Qwen3 1.7B measured ~100 tok/s on an iPhone 18 Pro Max with no
    /// thermal slowdown, in LLMEval with the same library versions.)
    public static func recommendedFirstModel(
        in catalog: [ModelSpec] = presets, fit: (ModelSpec) -> MemoryFit
    ) -> ModelSpec? {
        for id in [qwen3_1_7B.id, qwen3_0_6B.id] {
            if let spec = catalog.first(where: { $0.id == id }), fit(spec) == .ok {
                return spec
            }
        }
        return nil
    }

    // MARK: - Qwen3 (Apache-2.0)

    // verifiedOnDevice: device 2026-11-18 (180–186 tok/s on the long turn). Static: model_type
    // `qwen3`; in mlx-swift-lm's own LLMRegistry.
    public static let qwen3_0_6B = ModelSpec.qwen3(
        id: "qwen3-0.6b-4bit",
        repoID: "mlx-community/Qwen3-0.6B-4bit",
        revision: "73e3e38d981303bc594367cd910ea6eb48349da8",
        displayName: "Qwen3 0.6B",
        parameterCountLabel: "0.6B",
        downloadBytes: 349_711_765,
        layers: 28,
        blurbKey: "model.qwen3-0.6b.blurb",
        englishBlurb: "Smallest and fastest. Fine for quick questions, but makes more mistakes."
    )

    // verifiedOnDevice: device 2026-11-18, thinking off and on (89 tok/s sampled, 95.5 greedy;
    // 87–88 with thinking). Without thinking it often picks a number outside "between 11 and 49"
    // (also greedy); looks like a model limitation, not cross-checked against a reference (see
    // CLAUDE.md, Known pitfalls). Static: model_type `qwen3`; in LLMRegistry.
    public static let qwen3_1_7B = ModelSpec.qwen3(
        id: "qwen3-1.7b-4bit",
        repoID: "mlx-community/Qwen3-1.7B-4bit",
        revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
        displayName: "Qwen3 1.7B",
        parameterCountLabel: "1.7B",
        downloadBytes: 982_341_391,
        layers: 28,
        blurbKey: "model.qwen3-1.7b.blurb",
        englishBlurb: "Balanced size and quality for everyday chat."
    )

    // verifiedOnDevice: device 2026-11-18 (41.2 tok/s on the long turn, thermal state nominal).
    // Earlier, LLMEval with the same library versions on the same phone: ~45 tok/s, ~11% slower
    // with thermal state 2 after ~100 s of continuous generation in a case (no slowdown with
    // external cooling); hence the blurb's warm-up note. Static: model_type `qwen3`; in
    // LLMRegistry.
    public static let qwen3_4B = ModelSpec.qwen3(
        id: "qwen3-4b-4bit",
        repoID: "mlx-community/Qwen3-4B-4bit",
        revision: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25",
        displayName: "Qwen3 4B",
        parameterCountLabel: "4B",
        downloadBytes: 2_277_297_903,
        layers: 36,
        blurbKey: "model.qwen3-4b.blurb",
        englishBlurb:
            "The strongest Qwen3 here. Slower and needs more memory, and long replies slow down as the phone warms up."
    )

    // MARK: - SmolLM3 (Apache-2.0)

    /// HuggingFaceTB/SmolLM3-3B, MLX 4-bit (group 64).
    ///
    /// Derived from the pinned revision's files:
    /// - `config.json`: model_type `smollm3`, 36 layers, 4 KV heads, hidden 2048 / 16 heads →
    ///   head_dim 128 → KV 2·36·4·128·2 = 73,728 B/token; max_position_embeddings 65,536;
    ///   eos_token_id 128012 (`<|im_end|>`); no `tie_word_embeddings` (SmolLM3.swift defaults it
    ///   to true, and the weights have no `lm_head`).
    /// - `generation_config.json`: eos 128012, temperature 0.6, top_p 0.95.
    /// - `tokenizer_config.json` / `special_tokens_map.json`: eos `<|im_end|>`; `<think>` (128002)
    ///   and `</think>` (128003) are non-special, so they reach the ThinkingParser as text.
    /// - `chat_template.jinja`: thinking switch is `enable_thinking` (defaults to **true** when not
    ///   passed; `/think` or `/no_think` in the system prompt overrides it). Off → the template
    ///   appends `<think>\n\n</think>\n`, same mechanism as Qwen3. The template always injects a
    ///   "## Metadata" system header with today's date (`strftime_now`) and a default persona;
    ///   it closes the system turn with `<|im_end|>` only when tools are present (identical in
    ///   upstream main). Rendered fine with swift-jinja 2.3.1, with and without a system message.
    /// - Upstream card: "We recommend setting temperature=0.6 and top_p=0.95"; natively supports
    ///   English, French, Spanish, German, Italian, Portuguese.
    /// - Extra EOS: none needed (stop set = {128012}, which is upstream's generation_config too).
    ///
    /// verifiedOnDevice: device 2026-11-18 (53.5 tok/s on the long turn, thinking off). With
    /// thinking on (one run) turn 3 put the whole answer inside `<think>` and ended without
    /// `</think>`; see `ChatMessage.promoteUnterminatedThinkingIfNeeded()`. Not tried in Chinese.
    /// Static: SmolLM3Configuration decodes this config (all required keys present;
    /// `rope_scaling: null` is optional); in LLMRegistry (`smollm3_3b_4bit`).
    public static let smolLM3_3B = ModelSpec(
        id: "smollm3-3b-4bit",
        repoID: "mlx-community/SmolLM3-3B-4bit",
        revision: "d3a7e0594d6642dbcfb7d149bed8b0bdf49f95ce",
        displayName: "SmolLM3 3B",
        family: .smolLM,
        parameterCountLabel: "3B",
        quantization: .fourBit,
        downloadBytes: 1_747_378_363,
        license: .apache2,
        supportsThinkingToggle: true,
        sampling: SamplingDefaults(temperature: 0.6, topP: 0.95, topK: 0, minP: 0, maxTokens: 1024),
        thinkingSampling: SamplingDefaults(
            temperature: 0.6, topP: 0.95, topK: 0, minP: 0, maxTokens: 2048),
        blurbKey: "model.smollm3-3b.blurb",
        englishBlurb:
            "Hugging Face's fully open 3B model with a thinking mode. Best in English and five European languages.",
        runtime: RuntimeProfile(layers: 36, kvHeads: 4, headDim: 128, maxContextTokens: 65_536),
        extraEOSTokens: []
    )

    // MARK: - Phi-4-mini (MIT)

    /// microsoft/Phi-4-mini-instruct, MLX 4-bit (group 64).
    ///
    /// Derived from the pinned revision's files:
    /// - `config.json`: model_type `phi3`, 32 layers, 8 KV heads, hidden 3072 / 24 heads →
    ///   head_dim 128 (Phi3.swift uses hidden/heads) → KV 2·32·8·128·2 = 131,072 B/token;
    ///   max_position_embeddings 131,072 (original 4,096, `longrope` scaling,
    ///   partial_rotary_factor 0.75); tie_word_embeddings true (no `lm_head` in the weights);
    ///   eos_token_id 200020 (`<|end|>`).
    /// - No `generation_config.json` in this repo. Tokenizer eos is `<|endoftext|>` (199999), so
    ///   the stop set is {200020, 199999} — exactly upstream's generation_config
    ///   `eos_token_id: [200020, 199999]`. Extra EOS: none needed.
    /// - Chat template (in `tokenizer_config.json`, no `.jinja` file):
    ///   `<|system|>…<|end|><|user|>…<|end|><|assistant|>`; no thinking switch.
    /// - Upstream card gives no sampling recommendation; its examples use greedy decoding
    ///   (`temperature: 0.0, do_sample: False`, `max_new_tokens: 500`), which is what is used
    ///   here (temperature 0 selects argmax in mlx-swift-lm).
    ///
    /// verifiedOnDevice: device 2026-11-18 (45.2 tok/s on the long turn; one greedy run, a
    /// 360-token reply that ended at EOS with no repetition loop). Not tried in Chinese.
    /// Static: Phi3Configuration decodes this config (`original_max_position_embeddings`
    /// present, `longrope` long/short factor arrays of 48 = rope dims/2 for 0.75 × 128).
    public static let phi4Mini = ModelSpec(
        id: "phi-4-mini-4bit",
        repoID: "mlx-community/Phi-4-mini-instruct-4bit",
        revision: "ac1c269cb4222a4e136a3d09edad301056c1f36a",
        displayName: "Phi-4-mini",
        family: .phi,
        parameterCountLabel: "3.8B",
        quantization: .fourBit,
        downloadBytes: 2_177_574_851,
        license: ModelLicense(
            id: "mit",
            url: URL(
                string: "https://huggingface.co/microsoft/Phi-4-mini-instruct/resolve/main/LICENSE")!),
        supportsThinkingToggle: false,
        sampling: SamplingDefaults(temperature: 0, topP: 1, topK: 0, minP: 0, maxTokens: 1024),
        thinkingSampling: nil,
        blurbKey: "model.phi-4-mini.blurb",
        englishBlurb: "Microsoft's 3.8B model, strong at reasoning and math. No thinking mode.",
        runtime: RuntimeProfile(layers: 32, kvHeads: 8, headDim: 128, maxContextTokens: 131_072),
        extraEOSTokens: []
    )
}

extension ModelSpec {
    /// Shared shape of the Qwen3 dense 4-bit MLX conversions (8 KV heads, head_dim 128,
    /// 40,960-token context, Apache-2.0, thinking switch `enable_thinking`).
    ///
    /// The mlx-community Qwen3 repos ship no `generation_config.json`, so only
    /// `<|im_end|>` (from `config.json`) would stop generation. Upstream Qwen3 also stops on
    /// `<|endoftext|>`, so it is added as an extra EOS token.
    static func qwen3(
        id: String,
        repoID: String,
        revision: String,
        displayName: String,
        parameterCountLabel: String,
        downloadBytes: Int64,
        layers: Int,
        blurbKey: String,
        englishBlurb: String
    ) -> ModelSpec {
        ModelSpec(
            id: id,
            repoID: repoID,
            revision: revision,
            displayName: displayName,
            family: .qwen3,
            parameterCountLabel: parameterCountLabel,
            quantization: .fourBit,
            downloadBytes: downloadBytes,
            license: .apache2,
            supportsThinkingToggle: true,
            sampling: SamplingDefaults(
                temperature: 0.7, topP: 0.8, topK: 20, minP: 0, maxTokens: 1024),
            thinkingSampling: SamplingDefaults(
                temperature: 0.6, topP: 0.95, topK: 20, minP: 0, maxTokens: 2048),
            blurbKey: blurbKey,
            englishBlurb: englishBlurb,
            runtime: RuntimeProfile(
                layers: layers, kvHeads: 8, headDim: 128, maxContextTokens: 40_960),
            extraEOSTokens: ["<|endoftext|>"]
        )
    }
}

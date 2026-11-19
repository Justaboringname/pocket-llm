import Foundation

/// A model the app can download and run, described without any MLX types.
///
/// Instances normally come from ``ModelCatalog/presets``. Every field the UI or the memory
/// math needs is here so that adding a model is a one-entry change in `ModelCatalog.swift`.
public struct ModelSpec: Identifiable, Hashable, Sendable, Codable {
    /// Stable catalog identifier, safe for file names (lowercase letters, digits, `.`, `-`, `_`).
    /// This is also the value accepted by the `LLM_SELFTEST` environment variable.
    public let id: String
    /// Hugging Face repository id, e.g. `mlx-community/Qwen3-0.6B-4bit`.
    public let repoID: String
    /// Git revision to download. Pin a full commit hash for reproducible downloads; the
    /// Hugging Face cache can then answer "is everything here?" without any network request.
    public let revision: String
    /// Human-readable name (not localized: model names are proper nouns).
    public let displayName: String
    public let family: ModelFamily
    /// Parameter count as shown in the UI, e.g. "0.6B".
    public let parameterCountLabel: String
    public let quantization: Quantization
    /// Approximate download size in bytes: the sum of the files matched by
    /// ``ModelDownloadPatterns/all`` at ``revision``. Also used as the weights size for the
    /// memory estimate (safetensors dominate).
    public let downloadBytes: Int64
    public let license: ModelLicense
    /// Whether the chat template understands `enable_thinking` (Qwen3 style `<think>` blocks).
    public let supportsThinkingToggle: Bool
    /// Recommended sampling when thinking is off (or unsupported).
    public let sampling: SamplingDefaults
    /// Recommended sampling when thinking is on. `nil` means "same as ``sampling``".
    public let thinkingSampling: SamplingDefaults?
    /// Localization key of a one-sentence description, resolved by ``localizedBlurb``.
    public let blurbKey: String
    /// English text used when ``blurbKey`` is not (yet) in the String Catalog.
    public let englishBlurb: String?
    /// Architecture numbers needed for the memory estimate and context limits.
    public let runtime: RuntimeProfile
    /// Extra end-of-sequence token strings, passed to the MLX model configuration.
    public let extraEOSTokens: [String]

    public init(
        id: String,
        repoID: String,
        revision: String,
        displayName: String,
        family: ModelFamily,
        parameterCountLabel: String,
        quantization: Quantization,
        downloadBytes: Int64,
        license: ModelLicense,
        supportsThinkingToggle: Bool,
        sampling: SamplingDefaults,
        thinkingSampling: SamplingDefaults? = nil,
        blurbKey: String,
        englishBlurb: String? = nil,
        runtime: RuntimeProfile,
        extraEOSTokens: [String] = []
    ) {
        self.id = id
        self.repoID = repoID
        self.revision = revision
        self.displayName = displayName
        self.family = family
        self.parameterCountLabel = parameterCountLabel
        self.quantization = quantization
        self.downloadBytes = downloadBytes
        self.license = license
        self.supportsThinkingToggle = supportsThinkingToggle
        self.sampling = sampling
        self.thinkingSampling = thinkingSampling
        self.blurbKey = blurbKey
        self.englishBlurb = englishBlurb
        self.runtime = runtime
        self.extraEOSTokens = extraEOSTokens
    }

    /// Sampling defaults for the given thinking mode.
    public func recommendedSampling(thinking: Bool) -> SamplingDefaults {
        if thinking, supportsThinkingToggle, let thinkingSampling {
            return thinkingSampling
        }
        return sampling
    }

    /// The localized one-sentence description. Falls back to ``englishBlurb`` (then the key)
    /// when the key is missing from the package's String Catalog.
    public var localizedBlurb: String {
        Bundle.module.localizedString(forKey: blurbKey, value: englishBlurb, table: nil)
    }
}

/// Model family, open-ended so new families do not require an enum change.
public struct ModelFamily: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let qwen3 = ModelFamily(rawValue: "qwen3")
    public static let gemma = ModelFamily(rawValue: "gemma")
    public static let llama = ModelFamily(rawValue: "llama")
    public static let phi = ModelFamily(rawValue: "phi")
    public static let smolLM = ModelFamily(rawValue: "smollm")
}

/// Weight quantization as shown to the user.
public struct Quantization: Hashable, Sendable, Codable {
    /// Short label, e.g. "4-bit".
    public let label: String
    /// Nominal bits per weight (informational).
    public let bitsPerWeight: Double

    public init(label: String, bitsPerWeight: Double) {
        self.label = label
        self.bitsPerWeight = bitsPerWeight
    }

    public static let fourBit = Quantization(label: "4-bit", bitsPerWeight: 4)
    public static let eightBit = Quantization(label: "8-bit", bitsPerWeight: 8)
}

/// License identifier (SPDX where possible) and a URL to its text.
public struct ModelLicense: Hashable, Sendable, Codable {
    public let id: String
    public let url: URL

    public init(id: String, url: URL) {
        self.id = id
        self.url = url
    }

    public static let apache2 = ModelLicense(
        id: "apache-2.0", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
}

/// Recommended sampling parameters for a model.
public struct SamplingDefaults: Hashable, Sendable, Codable {
    public var temperature: Float
    public var topP: Float
    /// 0 disables top-k.
    public var topK: Int
    /// 0 disables min-p.
    public var minP: Float
    /// Default cap on generated tokens per reply.
    public var maxTokens: Int

    public init(temperature: Float, topP: Float, topK: Int = 0, minP: Float = 0, maxTokens: Int) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.maxTokens = maxTokens
    }
}

/// Architecture numbers used by the memory estimate.
public struct RuntimeProfile: Hashable, Sendable, Codable {
    /// KV-cache bytes per token at fp16:
    /// `2 (K and V) × num_hidden_layers × num_key_value_heads × head_dim × 2 bytes`.
    public let kvCacheBytesPerToken: Int64
    /// The model's maximum context length (`max_position_embeddings`).
    public let maxContextTokens: Int

    public init(kvCacheBytesPerToken: Int64, maxContextTokens: Int) {
        self.kvCacheBytesPerToken = kvCacheBytesPerToken
        self.maxContextTokens = maxContextTokens
    }

    /// Convenience: compute ``kvCacheBytesPerToken`` from `config.json` numbers.
    public init(layers: Int, kvHeads: Int, headDim: Int, maxContextTokens: Int) {
        self.init(
            kvCacheBytesPerToken: Int64(2 * layers * kvHeads * headDim * 2),
            maxContextTokens: maxContextTokens)
    }
}

/// File patterns downloaded for every model. Mirrors `modelDownloadPatterns` in
/// mlx-swift-lm (`MLXLMCommon/ModelFactory.swift`), which is `package`-scoped there.
public enum ModelDownloadPatterns {
    public static let all = ["*.safetensors", "*.json", "*.jinja"]
}

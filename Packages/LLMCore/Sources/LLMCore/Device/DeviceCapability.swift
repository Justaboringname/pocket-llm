import Foundation

/// Memory numbers measured at runtime (see ``MemoryProbe``) or injected by tests.
public struct MemorySnapshot: Hashable, Sendable, Codable {
    /// `ProcessInfo.physicalMemory` (for display; not the limit).
    public var physicalMemoryBytes: UInt64
    /// The process's current physical footprint (`task_vm_info.phys_footprint`), which is what
    /// jetsam compares with the limit. On iOS, Metal/MLX buffers count towards it.
    public var footprintBytes: UInt64
    /// `os_proc_available_memory()`: bytes the process can still allocate before reaching its
    /// limit. `nil` where unavailable (macOS) or when the call reports 0 (simulator).
    public var availableBytes: UInt64?

    public init(physicalMemoryBytes: UInt64, footprintBytes: UInt64, availableBytes: UInt64?) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.footprintBytes = footprintBytes
        self.availableBytes = availableBytes
    }

    /// The process memory limit = footprint + available (iOS only).
    public var processLimitBytes: UInt64? {
        availableBytes.map { $0 + footprintBytes }
    }
}

/// Estimated memory needed to run a model, split into its parts.
public struct MemoryEstimate: Hashable, Sendable, Codable {
    public var weightsBytes: Int64
    public var kvCacheBytes: Int64
    public var runtimeOverheadBytes: Int64

    public var totalBytes: Int64 { weightsBytes + kvCacheBytes + runtimeOverheadBytes }
}

/// Result of checking whether a model fits in the memory this process may use.
public enum MemoryFit: Hashable, Sendable {
    /// Fits with comfortable headroom.
    case ok
    /// Fits, but with little headroom; other apps or a long chat may push it over.
    case tight
    /// Will not fit. Loading is refused; `reason` is a localized explanation.
    case tooLarge(reason: String)

    public var allowsLoading: Bool {
        if case .tooLarge = self { return false }
        return true
    }
}

/// The constants of the memory estimate, in one place.
///
/// `required = weights × weightsFactor + kvBytesPerToken × contextTokens + runtimeOverhead`
///
/// - `weights`: ``ModelSpec/downloadBytes`` (safetensors dominate the download; quantization
///   scales are included in that size).
/// - `weightsFactor` 1.10: allocator rounding and buffers alive while weights load.
/// - KV cache: fp16, ``RuntimeProfile/kvCacheBytesPerToken`` × (prompt budget + max new
///   tokens). For small models this is as large as the weights, so it is not lumped into a
///   constant.
/// - `runtimeOverhead` 400 MB: prefill activations (512-token chunks, including a
///   512 × 151,936-entry logits buffer for Qwen3), the tokenizer, and the MLX runtime.
///
/// Budget: `os_proc_available_memory()` + memory that loading would free (the currently loaded
/// model). `ok` when `required ≤ okFraction × budget`, `tight` when `required ≤ budget`,
/// otherwise `tooLarge`. When the available memory is unknown (simulator, macOS), the budget
/// falls back to `unknownBudgetFraction × physical memory`.
public struct MemoryFitPolicy: Hashable, Sendable {
    public var weightsFactor: Double = 1.10
    public var runtimeOverheadBytes: Int64 = 400 * 1024 * 1024
    public var okFraction: Double = 0.80
    public var unknownBudgetFraction: Double = 0.5

    public init() {}

    public static let standard = MemoryFitPolicy()
}

/// Pure memory-fit math plus a convenience that measures the device at call time.
public struct DeviceCapability: Sendable {
    public var policy: MemoryFitPolicy
    private let measure: @Sendable () -> MemorySnapshot

    public init(
        policy: MemoryFitPolicy = .standard,
        measure: @escaping @Sendable () -> MemorySnapshot = { MemoryProbe.current() }
    ) {
        self.policy = policy
        self.measure = measure
    }

    /// Measures memory now.
    public func snapshot() -> MemorySnapshot { measure() }

    /// Fit for `spec` with the given context size, measured now.
    /// - Parameter reclaimableBytes: memory that loading `spec` would free first (the estimate
    ///   of the currently loaded model), 0 if nothing is loaded.
    public func fit(
        for spec: ModelSpec,
        contextTokens: Int = GenerationOptions.defaultPromptTokenBudget + 2048,
        reclaimableBytes: Int64 = 0
    ) -> MemoryFit {
        Self.fit(
            for: spec, contextTokens: contextTokens, snapshot: measure(),
            reclaimableBytes: reclaimableBytes, policy: policy)
    }

    // MARK: - Pure functions

    public static func estimate(
        for spec: ModelSpec, contextTokens: Int, policy: MemoryFitPolicy = .standard
    ) -> MemoryEstimate {
        let tokens = Int64(max(0, min(contextTokens, spec.runtime.maxContextTokens)))
        return MemoryEstimate(
            weightsBytes: Int64((Double(spec.downloadBytes) * policy.weightsFactor).rounded(.up)),
            kvCacheBytes: spec.runtime.kvCacheBytesPerToken * tokens,
            runtimeOverheadBytes: policy.runtimeOverheadBytes)
    }

    /// Bytes this process may use for a model.
    public static func budget(
        snapshot: MemorySnapshot, reclaimableBytes: Int64 = 0,
        policy: MemoryFitPolicy = .standard
    ) -> Int64 {
        if let available = snapshot.availableBytes, available > 0 {
            return Int64(clamping: available) + max(0, reclaimableBytes)
        }
        return Int64(Double(snapshot.physicalMemoryBytes) * policy.unknownBudgetFraction)
    }

    public static func fit(
        estimate: MemoryEstimate, budgetBytes: Int64, modelName: String,
        policy: MemoryFitPolicy = .standard
    ) -> MemoryFit {
        let required = estimate.totalBytes
        if Double(required) <= policy.okFraction * Double(budgetBytes) {
            return .ok
        }
        if required <= budgetBytes {
            return .tight
        }
        let needed = ByteFormatting.string(required)
        let available = ByteFormatting.string(max(0, budgetBytes))
        return .tooLarge(
            reason: String(
                localized:
                    "\(modelName) needs about \(needed) of memory, but this app can use only \(available) right now.",
                bundle: .module))
    }

    public static func fit(
        for spec: ModelSpec, contextTokens: Int, snapshot: MemorySnapshot,
        reclaimableBytes: Int64 = 0, policy: MemoryFitPolicy = .standard
    ) -> MemoryFit {
        fit(
            estimate: estimate(for: spec, contextTokens: contextTokens, policy: policy),
            budgetBytes: budget(
                snapshot: snapshot, reclaimableBytes: reclaimableBytes, policy: policy),
            modelName: spec.displayName,
            policy: policy)
    }
}

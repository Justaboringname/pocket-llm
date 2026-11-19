import Foundation
import Testing

@testable import LLMCore

@Suite("Memory fit")
struct MemoryFitTests {
    let spec = ModelCatalog.qwen3_0_6B
    let MiB: Int64 = 1024 * 1024
    let GiB: Int64 = 1024 * 1024 * 1024

    @Test func estimateFollowsDocumentedFormula() {
        let estimate = DeviceCapability.estimate(for: spec, contextTokens: 6144)
        #expect(estimate.weightsBytes == Int64((Double(349_711_765) * 1.10).rounded(.up)))
        #expect(estimate.kvCacheBytes == 114_688 * 6144)
        #expect(estimate.runtimeOverheadBytes == 400 * MiB)
        #expect(
            estimate.totalBytes
                == estimate.weightsBytes + estimate.kvCacheBytes + estimate.runtimeOverheadBytes)
    }

    @Test func kvCacheDominatesForSmallModels() {
        // The reason KV is not folded into a constant: for 0.6B at 6K context it exceeds the
        // weights.
        let estimate = DeviceCapability.estimate(for: spec, contextTokens: 6144)
        #expect(estimate.kvCacheBytes > Int64(spec.downloadBytes))
    }

    @Test func contextIsClampedToModelMaximum() {
        let huge = DeviceCapability.estimate(for: spec, contextTokens: 10_000_000)
        #expect(huge.kvCacheBytes == spec.runtime.kvCacheBytesPerToken * 40_960)
        let negative = DeviceCapability.estimate(for: spec, contextTokens: -5)
        #expect(negative.kvCacheBytes == 0)
    }

    @Test func thresholds() {
        let estimate = MemoryEstimate(weightsBytes: 800 * MiB, kvCacheBytes: 0, runtimeOverheadBytes: 0)
        // ok: required ≤ 80 % of budget
        #expect(DeviceCapability.fit(estimate: estimate, budgetBytes: 1000 * MiB, modelName: "M") == .ok)
        // tight: 80 % < required ≤ budget
        #expect(DeviceCapability.fit(estimate: estimate, budgetBytes: 999 * MiB, modelName: "M") == .tight)
        #expect(DeviceCapability.fit(estimate: estimate, budgetBytes: 800 * MiB, modelName: "M") == .tight)
        // too large
        let result = DeviceCapability.fit(estimate: estimate, budgetBytes: 799 * MiB, modelName: "Model X")
        guard case .tooLarge(let reason) = result else {
            Issue.record("expected tooLarge, got \(result)")
            return
        }
        #expect(reason.contains("Model X"))
        #expect(result.allowsLoading == false)
    }

    @Test func budgetUsesAvailablePlusReclaimable() {
        let snapshot = MemorySnapshot(
            physicalMemoryBytes: UInt64(12 * GiB), footprintBytes: UInt64(300 * MiB),
            availableBytes: UInt64(2 * GiB))
        #expect(DeviceCapability.budget(snapshot: snapshot) == 2 * GiB)
        #expect(DeviceCapability.budget(snapshot: snapshot, reclaimableBytes: GiB) == 3 * GiB)
        #expect(snapshot.processLimitBytes == UInt64(2 * GiB + 300 * MiB))
    }

    @Test func unknownAvailabilityFallsBackToHalfOfPhysicalMemory() {
        let snapshot = MemorySnapshot(
            physicalMemoryBytes: UInt64(8 * GiB), footprintBytes: 0, availableBytes: nil)
        #expect(DeviceCapability.budget(snapshot: snapshot) == 4 * GiB)
        #expect(snapshot.processLimitBytes == nil)
    }

    @Test func realisticPhoneNumbers() {
        // ~6 GiB allowance (typical for a recent Pro iPhone with the entitlement).
        let snapshot = MemorySnapshot(
            physicalMemoryBytes: UInt64(12 * GiB), footprintBytes: UInt64(150 * MiB),
            availableBytes: UInt64(6 * GiB))
        let context = GenerationOptions.recommended(for: ModelCatalog.qwen3_4B, thinking: true)
            .contextTokens
        #expect(
            DeviceCapability.fit(for: ModelCatalog.qwen3_0_6B, contextTokens: context, snapshot: snapshot)
                == .ok)
        #expect(
            DeviceCapability.fit(for: ModelCatalog.qwen3_4B, contextTokens: context, snapshot: snapshot)
                == .ok)
        // A 3 GiB allowance is too small for 4B at 6K context.
        let small = MemorySnapshot(
            physicalMemoryBytes: UInt64(6 * GiB), footprintBytes: UInt64(150 * MiB),
            availableBytes: UInt64(3 * GiB))
        #expect(
            DeviceCapability.fit(for: ModelCatalog.qwen3_4B, contextTokens: context, snapshot: small)
                .allowsLoading == false)
    }

    @Test func injectedMeasurementIsUsed() {
        let capability = DeviceCapability(measure: {
            MemorySnapshot(physicalMemoryBytes: 1 << 30, footprintBytes: 0, availableBytes: 1 << 20)
        })
        #expect(capability.fit(for: ModelCatalog.qwen3_0_6B).allowsLoading == false)
    }

    @Test func liveProbeReturnsPlausibleNumbers() {
        let snapshot = MemoryProbe.current()
        #expect(snapshot.physicalMemoryBytes > 0)
        #expect(snapshot.footprintBytes > 0)
        #if os(macOS)
            #expect(snapshot.availableBytes == nil)
        #endif
    }
}

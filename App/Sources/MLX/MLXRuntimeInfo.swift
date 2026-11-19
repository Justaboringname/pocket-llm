import Foundation
import MLX

/// MLX allocator numbers for diagnostics (self-test output). `nil` in the simulator, where MLX
/// must not be touched.
enum MLXRuntimeInfo {
    struct Snapshot: Codable, Sendable {
        let activeBytes: Int
        let cacheBytes: Int
        let peakBytes: Int
        let cacheLimitBytes: Int
    }

    static func snapshot() -> Snapshot? {
        #if targetEnvironment(simulator)
            return nil
        #else
            return Snapshot(
                activeBytes: Memory.activeMemory,
                cacheBytes: Memory.cacheMemory,
                peakBytes: Memory.peakMemory,
                cacheLimitBytes: Memory.cacheLimit)
        #endif
    }
}

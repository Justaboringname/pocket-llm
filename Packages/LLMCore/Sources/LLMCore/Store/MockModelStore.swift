import Foundation
import Observation

/// A simulated ``ModelStore`` for the simulator, previews and tests. Nothing touches the
/// network or writes model files; state lives in memory.
@Observable
@MainActor
public final class MockModelStore: ModelStore {
    public let catalog: [ModelSpec]
    public private(set) var states: [String: ModelInstallState]

    /// Number of progress steps per simulated download.
    @ObservationIgnored public var steps: Int
    /// Delay per step.
    @ObservationIgnored public var stepDelay: Duration
    /// Simulated free disk space (`nil` = unknown).
    @ObservationIgnored public var simulatedFreeBytes: Int64?
    /// When set, the next download fails with this message.
    @ObservationIgnored public var nextDownloadFailure: String?

    @ObservationIgnored private var tasks: [String: Task<Void, Error>] = [:]

    public init(
        catalog: [ModelSpec] = ModelCatalog.presets,
        downloaded: Set<String> = [],
        steps: Int = 20,
        stepDelay: Duration = .milliseconds(100),
        simulatedFreeBytes: Int64? = 64 * 1024 * 1024 * 1024
    ) {
        self.catalog = catalog
        self.steps = max(1, steps)
        self.stepDelay = stepDelay
        self.simulatedFreeBytes = simulatedFreeBytes
        var states: [String: ModelInstallState] = [:]
        for spec in catalog {
            states[spec.id] =
                downloaded.contains(spec.id)
                ? .downloaded(bytesOnDisk: spec.downloadBytes) : .notDownloaded
        }
        self.states = states
    }

    public func state(for spec: ModelSpec) -> ModelInstallState {
        states[spec.id] ?? .notDownloaded
    }

    public func download(_ spec: ModelSpec) async throws {
        if let task = tasks[spec.id] {
            try await task.value
            return
        }
        if state(for: spec).isDownloaded { return }
        if let free = simulatedFreeBytes, free < spec.downloadBytes {
            let error = ModelStoreError.insufficientDiskSpace(
                requiredBytes: spec.downloadBytes, availableBytes: free)
            states[spec.id] = .failed(message: error.localizedDescription)
            throw error
        }
        let failure = nextDownloadFailure
        nextDownloadFailure = nil
        let steps = self.steps
        let delay = stepDelay
        states[spec.id] = .downloading(progress: 0, bytesReceived: 0, bytesTotal: spec.downloadBytes)

        let task = Task<Void, Error> { @MainActor [weak self] in
            for step in 1...steps {
                try await Task.sleep(for: delay)
                if let failure, step == steps / 2 + 1 {
                    throw MockDownloadFailure(message: failure)
                }
                let fraction = Double(step) / Double(steps)
                self?.states[spec.id] = .downloading(
                    progress: fraction,
                    bytesReceived: Int64(Double(spec.downloadBytes) * fraction),
                    bytesTotal: spec.downloadBytes)
            }
        }
        tasks[spec.id] = task
        do {
            try await task.value
            tasks[spec.id] = nil
            states[spec.id] = .downloaded(bytesOnDisk: spec.downloadBytes)
        } catch {
            tasks[spec.id] = nil
            if error is CancellationError {
                states[spec.id] = .notDownloaded
                throw error
            }
            states[spec.id] = .failed(message: failure ?? error.localizedDescription)
            throw error
        }
    }

    public func cancelDownload(_ spec: ModelSpec) {
        tasks[spec.id]?.cancel()
    }

    public func delete(_ spec: ModelSpec) async throws {
        if let task = tasks[spec.id] {
            task.cancel()
            _ = try? await task.value
        }
        tasks[spec.id] = nil
        states[spec.id] = .notDownloaded
    }

    public func localDirectory(for spec: ModelSpec) -> URL? {
        guard state(for: spec).isDownloaded else { return nil }
        return FileManager.default.temporaryDirectory.appending(
            path: "mock-models/\(spec.id)", directoryHint: .isDirectory)
    }

    public var totalBytesOnDisk: Int64 {
        catalog.reduce(0) { total, spec in
            if case .downloaded(let bytes) = state(for: spec) { return total + bytes }
            return total
        }
    }

    public func availableDiskBytes() -> Int64? { simulatedFreeBytes }
}

/// Error used by ``MockModelStore`` to simulate a failed download.
public struct MockDownloadFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

import Foundation
import Synchronization
import Testing

@testable import LLMCore

/// Writes fake model files under `<root>/hub/<id>/…` like a cache-backed downloader would.
final class FakeDownloader: ModelDownloader {
    enum Mode: Sendable {
        case success
        case fail(String)
        /// Writes a partial file, then waits until cancelled.
        case hangUntilCancelled
        /// Returns a directory without tokenizer.json.
        case incomplete
    }

    let root: URL
    private let state: Mutex<(mode: Mode, calls: Int, cleanups: Int)>

    init(root: URL, mode: Mode = .success) {
        self.root = root
        self.state = Mutex((mode, 0, 0))
    }

    var mode: Mode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    var calls: Int { state.withLock { $0.calls } }
    var cleanups: Int { state.withLock { $0.cleanups } }

    func repoDirectory(_ spec: ModelSpec) -> URL {
        root.appending(path: "hub/\(spec.id)", directoryHint: .isDirectory)
    }

    func download(
        _ spec: ModelSpec, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let mode = state.withLock {
            $0.calls += 1
            return $0.mode
        }
        let snapshot = repoDirectory(spec).appending(path: "snapshots/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let total: Int64 = 3000
        progress(DownloadProgress(completedBytes: 0, totalBytes: total))
        try Data(repeating: 1, count: 1000).write(to: snapshot.appending(path: "config.json"))
        progress(DownloadProgress(completedBytes: 1000, totalBytes: total))

        switch mode {
        case .success, .incomplete:
            break
        case .fail(let message):
            throw MockDownloadFailure(message: message)
        case .hangUntilCancelled:
            try await Task.sleep(for: .seconds(60))
        }

        if case .incomplete = mode {} else {
            try Data(repeating: 2, count: 1000).write(to: snapshot.appending(path: "tokenizer.json"))
        }
        progress(DownloadProgress(completedBytes: 2000, totalBytes: total))
        try Data(repeating: 3, count: 1000).write(to: snapshot.appending(path: "model.safetensors"))
        progress(DownloadProgress(completedBytes: 3000, totalBytes: total))
        return snapshot
    }

    func storageLocations(for spec: ModelSpec) -> [URL] {
        [repoDirectory(spec)]
    }

    func cleanUpTemporaryFiles() {
        state.withLock { $0.cleanups += 1 }
    }
}

@MainActor
@Suite("Model stores")
struct ModelStoreTests {
    let spec = ModelCatalog.qwen3_0_6B
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LLMCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeStore(_ downloader: FakeDownloader, free: Int64? = 100_000_000_000) throws
        -> LiveModelStore
    {
        try LiveModelStore(rootDirectory: root, downloader: downloader, freeSpace: { _ in free })
    }

    @Test func downloadInstallsAndSurvivesRelaunch() async throws {
        let downloader = FakeDownloader(root: root)
        let store = try makeStore(downloader)
        #expect(store.state(for: spec) == .notDownloaded)
        #expect(store.localDirectory(for: spec) == nil)
        #expect(FileUtilities.isExcludedFromBackup(root))

        try await store.download(spec)

        guard case .downloaded(let bytes) = store.state(for: spec) else {
            Issue.record("expected downloaded, got \(store.state(for: spec))")
            return
        }
        #expect(bytes >= 3000)
        #expect(store.totalBytesOnDisk == bytes)
        let directory = try #require(store.localDirectory(for: spec))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path))
        let manifest = root.appending(path: "manifests/\(spec.id).json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        let text = try String(contentsOf: manifest, encoding: .utf8)
        #expect(text.contains("\"relativeModelPath\" : \"hub/\(spec.id)/snapshots/abc\""))
        #expect(text.contains(root.path) == false, "paths in the manifest are relative")

        // "Relaunch": a new store over the same directory.
        let relaunched = try makeStore(FakeDownloader(root: root))
        #expect(relaunched.state(for: spec).isDownloaded)
        #expect(relaunched.localDirectory(for: spec) == directory)

        // Downloading again is a no-op.
        try await relaunched.download(spec)
        #expect(downloader.calls == 1)
        #expect(downloader.cleanups >= 1)
    }

    @Test func insufficientSpaceFailsBeforeDownloading() async throws {
        let downloader = FakeDownloader(root: root)
        let store = try makeStore(downloader, free: 10_000_000)
        await #expect(throws: ModelStoreError.self) {
            try await store.download(spec)
        }
        #expect(downloader.calls == 0)
        guard case .failed(let message) = store.state(for: spec) else {
            Issue.record("expected failed")
            return
        }
        #expect(message.isEmpty == false)
    }

    @Test func cancelKeepsPartialFilesAndAllowsRetry() async throws {
        let downloader = FakeDownloader(root: root, mode: .hangUntilCancelled)
        let store = try makeStore(downloader)
        let download = Task { try await store.download(spec) }

        try await waitUntil { store.state(for: spec).isDownloading && downloader.calls == 1 }
        try await waitUntil {
            if case .downloading(let progress, _, _) = store.state(for: spec) { return progress > 0 }
            return false
        }
        store.cancelDownload(spec)
        await #expect(throws: CancellationError.self) {
            try await download.value
        }
        #expect(store.state(for: spec) == .notDownloaded)
        #expect(store.localDirectory(for: spec) == nil)
        #expect(store.totalBytesOnDisk >= 1000, "completed files are kept for resume")

        downloader.mode = .success
        try await store.download(spec)
        #expect(store.state(for: spec).isDownloaded)
    }

    @Test func failureIsReported() async throws {
        let downloader = FakeDownloader(root: root, mode: .fail("network down"))
        let store = try makeStore(downloader)
        await #expect(throws: (any Error).self) {
            try await store.download(spec)
        }
        #expect(store.state(for: spec) == .failed(message: "network down"))
        // A new attempt clears the failure.
        downloader.mode = .success
        try await store.download(spec)
        #expect(store.state(for: spec).isDownloaded)
    }

    @Test func incompleteDownloadIsNotInstalled() async throws {
        let downloader = FakeDownloader(root: root, mode: .incomplete)
        let store = try makeStore(downloader)
        await #expect(throws: ModelStoreError.incompleteDownload(missing: ["tokenizer.json"])) {
            try await store.download(spec)
        }
        #expect(store.localDirectory(for: spec) == nil)
        #expect(store.state(for: spec).isDownloaded == false)
    }

    @Test func deleteRemovesFilesAndManifest() async throws {
        let downloader = FakeDownloader(root: root)
        let store = try makeStore(downloader)
        try await store.download(spec)
        try await store.delete(spec)
        #expect(store.state(for: spec) == .notDownloaded)
        #expect(store.totalBytesOnDisk == 0)
        #expect(FileManager.default.fileExists(atPath: downloader.repoDirectory(spec).path) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: "manifests/\(spec.id).json").path) == false)
    }

    @Test func manifestForAnotherRevisionIsIgnored() async throws {
        let downloader = FakeDownloader(root: root)
        let store = try makeStore(downloader)
        try await store.download(spec)

        let moved = ModelSpec(
            id: spec.id, repoID: spec.repoID, revision: String(repeating: "f", count: 40),
            displayName: spec.displayName, family: spec.family,
            parameterCountLabel: spec.parameterCountLabel, quantization: spec.quantization,
            downloadBytes: spec.downloadBytes, license: spec.license,
            supportsThinkingToggle: spec.supportsThinkingToggle, sampling: spec.sampling,
            blurbKey: spec.blurbKey, runtime: spec.runtime)
        let other = try LiveModelStore(
            catalog: [moved], rootDirectory: root, downloader: downloader, freeSpace: { _ in nil })
        #expect(other.state(for: moved) == .notDownloaded)
    }

    @Test func missingFilesInvalidateManifest() async throws {
        let downloader = FakeDownloader(root: root)
        let store = try makeStore(downloader)
        try await store.download(spec)
        let directory = try #require(store.localDirectory(for: spec))
        try FileManager.default.removeItem(at: directory.appending(path: "model.safetensors"))
        store.refresh()
        #expect(store.state(for: spec) == .notDownloaded)
    }

    @Test func invalidCatalogIDIsRejected() {
        let bad = ModelSpec(
            id: "../x", repoID: "a/b", revision: "main", displayName: "x", family: .qwen3,
            parameterCountLabel: "1B", quantization: .fourBit, downloadBytes: 1,
            license: .apache2, supportsThinkingToggle: false,
            sampling: SamplingDefaults(temperature: 1, topP: 1, maxTokens: 1), blurbKey: "k",
            runtime: RuntimeProfile(kvCacheBytesPerToken: 1, maxContextTokens: 1))
        #expect(throws: ModelStoreError.self) {
            _ = try LiveModelStore(
                catalog: [bad], rootDirectory: root, downloader: FakeDownloader(root: root))
        }
    }

    // MARK: Mock store

    @Test func mockStoreTransitions() async throws {
        let store = MockModelStore(steps: 4, stepDelay: .milliseconds(5))
        #expect(store.state(for: spec) == .notDownloaded)
        try await store.download(spec)
        #expect(store.state(for: spec) == .downloaded(bytesOnDisk: spec.downloadBytes))
        #expect(store.localDirectory(for: spec) != nil)
        #expect(store.totalBytesOnDisk == spec.downloadBytes)
        try await store.delete(spec)
        #expect(store.state(for: spec) == .notDownloaded)
    }

    @Test func mockStoreCancelAndFailure() async throws {
        let store = MockModelStore(steps: 50, stepDelay: .milliseconds(20))
        let task = Task { try await store.download(spec) }
        try await waitUntil { store.state(for: spec).isDownloading }
        store.cancelDownload(spec)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.state(for: spec) == .notDownloaded)

        store.steps = 2
        store.stepDelay = .milliseconds(1)
        store.nextDownloadFailure = "simulated"
        await #expect(throws: (any Error).self) { try await store.download(spec) }
        #expect(store.state(for: spec) == .failed(message: "simulated"))

        store.simulatedFreeBytes = 1
        await #expect(throws: ModelStoreError.self) { try await store.download(spec) }
    }
}

/// Polls `condition` on the main actor until it is true (fails after `timeout`).
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for condition", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

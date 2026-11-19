import Foundation
import Synchronization
import Testing

@testable import LLMCore

/// A downloader whose every call runs `step` (call number is 1-based) inside a fresh snapshot
/// directory `<root>/hub/<id>/snapshots/abc`, then returns that directory.
final class ScriptedDownloader: ModelDownloader {
    typealias Step = @Sendable (
        _ call: Int, _ snapshot: URL, _ progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> Void

    let root: URL
    private let step: Step
    private let calls = Mutex(0)

    init(root: URL, step: @escaping Step) {
        self.root = root
        self.step = step
    }

    var callCount: Int { calls.withLock { $0 } }

    func download(
        _ spec: ModelSpec, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let call = calls.withLock {
            $0 += 1
            return $0
        }
        let snapshot = root.appending(
            path: "hub/\(spec.id)/snapshots/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try await step(call, snapshot, progress)
        return snapshot
    }

    func storageLocations(for spec: ModelSpec) -> [URL] {
        [root.appending(path: "hub/\(spec.id)", directoryHint: .isDirectory)]
    }

    /// Writes 1,000-byte files.
    static func write(_ names: [String], in directory: URL) throws {
        for name in names {
            try Data(repeating: 7, count: 1000).write(to: directory.appending(path: name))
        }
    }

    static let allFiles = ["config.json", "tokenizer.json", "model.safetensors"]
}

/// A lock-protected value that closures can capture (a `Mutex` itself is noncopyable).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    func update(_ change: (inout Value) -> Void) { mutex.withLock { change(&$0) } }
}

/// Records the waits requested by ``DownloadRetryPolicy/run(sleep:onRetry:_:)``.
final class SleepRecorder: Sendable {
    private let delays = Mutex<[Duration]>([])
    var recorded: [Duration] { delays.withLock { $0 } }
    func sleep(_ delay: Duration) async throws {
        delays.withLock { $0.append(delay) }
        try Task.checkCancellation()
    }
}

/// Counts attempts and hands out scripted results.
final class AttemptScript: Sendable {
    private let state: Mutex<(attempts: Int, errors: [any Error & Sendable])>
    init(failures: [any Error & Sendable]) { state = Mutex((0, failures)) }
    var attempts: Int { state.withLock { $0.attempts } }
    func attempt() throws -> String {
        let error: (any Error & Sendable)? = state.withLock {
            $0.attempts += 1
            return $0.errors.isEmpty ? nil : $0.errors.removeFirst()
        }
        if let error { throw error }
        return "ok"
    }
}

@Suite("Download retry policy")
struct DownloadRetryPolicyTests {
    let fast = DownloadRetryPolicy(
        maxRetries: 3, initialDelay: .milliseconds(1), maxDelay: .milliseconds(8))

    // MARK: Classification

    @Test(arguments: [
        NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
    ])
    func transientURLErrors(_ code: Int) {
        #expect(DownloadRetryPolicy.classify(URLError(URLError.Code(rawValue: code))) == .transient)
    }

    @Test(arguments: [
        NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
    ])
    func offlineURLErrors(_ code: Int) {
        #expect(DownloadRetryPolicy.classify(URLError(URLError.Code(rawValue: code))) == .offline)
    }

    @Test func otherErrorsAreNotRetried() {
        #expect(DownloadRetryPolicy.classify(CancellationError()) == .cancelled)
        #expect(DownloadRetryPolicy.classify(URLError(.cancelled)) == .cancelled)
        #expect(DownloadRetryPolicy.classify(URLError(.serverCertificateUntrusted)) == .permanent)
        #expect(DownloadRetryPolicy.classify(URLError(.badURL)) == .permanent)
        #expect(DownloadRetryPolicy.classify(MockDownloadFailure(message: "x")) == .permanent)
        #expect(DownloadRetryPolicy.classify(CocoaError(.fileWriteOutOfSpace)) == .permanent)
        #expect(
            DownloadRetryPolicy.classify(
                ModelStoreError.insufficientDiskSpace(requiredBytes: 2, availableBytes: 1))
                == .permanent)
    }

    @Test func deviceErrorFromFirstRunIsTransient() {
        // What the phone reported: NSURLErrorDomain -1005 with _kCFStreamErrorCodeKey 53.
        let error = NSError(
            domain: NSURLErrorDomain, code: -1005,
            userInfo: [
                NSLocalizedDescriptionKey: "The network connection was lost.",
                "_kCFStreamErrorCodeKey": 53, "_kCFStreamErrorDomainKey": 1,
            ])
        #expect(DownloadRetryPolicy.classify(error) == .transient)
    }

    @Test func underlyingErrorsAreWalked() {
        let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: lost])
        let twice = NSError(domain: "Outer", code: 2, userInfo: [NSUnderlyingErrorKey: wrapped])
        #expect(DownloadRetryPolicy.classify(twice) == .transient)

        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(
            DownloadRetryPolicy.classify(
                NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: offline]))
                == .offline)

        // An undecided URL code (TLS failure) caused by a connection reset: transient.
        let reset = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECONNRESET.rawValue))
        let tls = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
            userInfo: [NSUnderlyingErrorKey: reset])
        #expect(DownloadRetryPolicy.classify(tls) == .transient)

        // CFNetwork's domain uses the same codes.
        #expect(
            DownloadRetryPolicy.classify(NSError(domain: "kCFErrorDomainCFNetwork", code: -1005))
                == .transient)
    }

    @Test func underlyingChainIsBounded() {
        var error = NSError(domain: "Leaf", code: 0)
        for index in 0..<20 {
            error = NSError(domain: "Level\(index)", code: index, userInfo: [NSUnderlyingErrorKey: error])
        }
        #expect(DownloadRetryPolicy.classify(error) == .permanent)
    }

    @Test func httpStatusClassification() {
        for status in [408, 429, 500, 502, 503, 504] {
            #expect(
                DownloadRetryPolicy.classify(ModelDownloadError.httpStatus(status, detail: ""))
                    == .transient)
        }
        for status in [400, 401, 403, 404, 416] {
            #expect(
                DownloadRetryPolicy.classify(ModelDownloadError.httpStatus(status, detail: ""))
                    == .permanent)
        }
        #expect(DownloadRetryPolicy.classify(ModelDownloadError.library("decoding")) == .permanent)
        #expect(
            DownloadRetryPolicy.classify(ModelStoreError.incompleteDownload(missing: ["x"]))
                == .transient)
    }

    // MARK: Delays

    @Test func delaysDoubleUpToTheCap() {
        let standard = DownloadRetryPolicy.standard
        #expect(standard.maxRetries == 3)
        #expect((1...3).map(standard.delay(beforeRetry:)) == [.seconds(1), .seconds(2), .seconds(4)])
        let capped = DownloadRetryPolicy(maxRetries: 5, initialDelay: .seconds(1), maxDelay: .seconds(3))
        #expect(
            (1...5).map(capped.delay(beforeRetry:))
                == [.seconds(1), .seconds(2), .seconds(3), .seconds(3), .seconds(3)])
        #expect(DownloadRetryPolicy(maxRetries: -2, initialDelay: .zero, maxDelay: .zero).maxRetries == 0)
    }

    // MARK: Running

    @Test func retriesTransientFailuresThenSucceeds() async throws {
        let script = AttemptScript(failures: [
            URLError(.networkConnectionLost), URLError(.timedOut),
        ])
        let sleeper = SleepRecorder()
        let records = Locked<[DownloadRetryRecord]>([])
        let result = try await DownloadRetryPolicy.standard.run(
            sleep: { try await sleeper.sleep($0) },
            onRetry: { record in records.update { $0.append(record) } },
            { try script.attempt() })
        #expect(result == "ok")
        #expect(script.attempts == 3)
        #expect(sleeper.recorded == [.seconds(1), .seconds(2)])
        let log = records.value
        #expect(log.map(\.retry) == [1, 2])
        #expect(log.map(\.errorCode) == [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut])
        #expect(log.allSatisfy { $0.errorDomain == NSURLErrorDomain })
        #expect(log.map(\.delaySeconds) == [1, 2])
    }

    @Test func givesUpAfterMaxRetriesWithTheLastError() async throws {
        let script = AttemptScript(failures: [
            URLError(.networkConnectionLost), URLError(.networkConnectionLost),
            URLError(.networkConnectionLost), URLError(.cannotFindHost),
        ])
        let sleeper = SleepRecorder()
        await #expect(throws: URLError(.cannotFindHost)) {
            try await DownloadRetryPolicy.standard.run(
                sleep: { try await sleeper.sleep($0) }, { try script.attempt() })
        }
        #expect(script.attempts == 4)
        #expect(sleeper.recorded.count == 3)
    }

    @Test func offlineFailsFastWithoutRetry() async throws {
        let script = AttemptScript(failures: [URLError(.notConnectedToInternet)])
        let sleeper = SleepRecorder()
        await #expect(throws: URLError(.notConnectedToInternet)) {
            try await fast.run(sleep: { try await sleeper.sleep($0) }, { try script.attempt() })
        }
        #expect(script.attempts == 1)
        #expect(sleeper.recorded.isEmpty)
    }

    @Test func permanentAndCancelledErrorsAreNotRetried() async throws {
        let notFound = AttemptScript(failures: [ModelDownloadError.httpStatus(404, detail: "")])
        await #expect(throws: ModelDownloadError.httpStatus(404, detail: "")) {
            try await fast.run { try notFound.attempt() }
        }
        #expect(notFound.attempts == 1)

        let cancelled = AttemptScript(failures: [URLError(.cancelled)])
        await #expect(throws: URLError(.cancelled)) {
            try await fast.run { try cancelled.attempt() }
        }
        #expect(cancelled.attempts == 1)
    }

    @Test func noRetriesPolicyRunsOnce() async throws {
        let script = AttemptScript(failures: [URLError(.networkConnectionLost)])
        await #expect(throws: URLError(.networkConnectionLost)) {
            try await DownloadRetryPolicy.none.run { try script.attempt() }
        }
        #expect(script.attempts == 1)
    }

    @Test func cancellationDuringBackoffReturnsPromptly() async throws {
        let slow = DownloadRetryPolicy(maxRetries: 3, initialDelay: .seconds(60), maxDelay: .seconds(60))
        let script = AttemptScript(failures: [URLError(.networkConnectionLost)])
        let task = Task { try await slow.run { try script.attempt() } }
        while script.attempts == 0 { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(script.attempts == 1, "a cancelled backoff never starts another attempt")
    }

    @Test func cancelledTaskWinsOverATransientError() async throws {
        let attempts = Locked(0)
        let fast = self.fast
        let task = Task {
            try await fast.run {
                attempts.update { $0 += 1 }
                // The cancel arrives while this attempt runs and the network error follows it.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
                throw URLError(.networkConnectionLost)
            }
        }
        while attempts.value == 0 { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(attempts.value == 1)
    }
}

@MainActor
@Suite("Live store retries")
struct LiveStoreRetryTests {
    let spec = ModelCatalog.qwen3_0_6B
    let root: URL
    let fast = DownloadRetryPolicy(
        maxRetries: 3, initialDelay: .milliseconds(1), maxDelay: .milliseconds(8))

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LLMCoreRetryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeStore(_ downloader: ScriptedDownloader, policy: DownloadRetryPolicy? = nil)
        throws -> LiveModelStore
    {
        try LiveModelStore(
            rootDirectory: root, downloader: downloader, retryPolicy: policy ?? fast,
            freeSpace: { _ in 100_000_000_000 })
    }

    @Test func connectionLostIsRetriedWithoutMovingProgressBackwards() async throws {
        let gate = TokenGate()
        let downloader = ScriptedDownloader(root: root) { call, snapshot, progress in
            if call == 1 {
                // Like the device run: small files done, then the big file fails.
                try ScriptedDownloader.write(["config.json", "tokenizer.json"], in: snapshot)
                progress(DownloadProgress(completedBytes: 2000, totalBytes: 3000))
                throw URLError(.networkConnectionLost)
            }
            // The retry starts its own count from zero before skipping the finished files.
            progress(DownloadProgress(completedBytes: 0, totalBytes: 3000))
            await gate.wait()
            try ScriptedDownloader.write(ScriptedDownloader.allFiles, in: snapshot)
            progress(DownloadProgress(completedBytes: 3000, totalBytes: 3000))
        }
        let store = try makeStore(downloader)
        let download = Task { try await store.download(spec) }

        try await waitUntil { downloader.callCount == 2 && gate.waitingCount == 1 }
        try await Task.sleep(for: .milliseconds(30))  // let queued progress reports land
        guard case .downloading(let fraction, let received, let total) = store.state(for: spec)
        else {
            Issue.record("expected downloading, got \(store.state(for: spec))")
            gate.open()
            return
        }
        #expect(abs(fraction - 2.0 / 3.0) < 0.0001, "the retry's 0 % report is ignored")
        #expect(received == 2000)
        #expect(total == 3000)
        #expect(store.downloadRetries(for: spec).map(\.errorCode) == [NSURLErrorNetworkConnectionLost])

        gate.open()
        try await download.value
        #expect(store.state(for: spec).isDownloaded)
        #expect(downloader.callCount == 2)
        #expect(store.downloadRetries(for: spec).count == 1)
    }

    @Test func exhaustedRetriesReportAFriendlyMessageAndTheOriginalError() async throws {
        let downloader = ScriptedDownloader(root: root) { _, _, _ in
            throw URLError(.networkConnectionLost)
        }
        let store = try makeStore(downloader)
        do {
            try await store.download(spec)
            Issue.record("expected a failure")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost, "the thrown error keeps its code")
        }
        #expect(downloader.callCount == 4)
        #expect(store.downloadRetries(for: spec).count == 3)
        guard case .failed(let message) = store.state(for: spec) else {
            Issue.record("expected failed, got \(store.state(for: spec))")
            return
        }
        #expect(message == LiveModelStore.failureMessage(for: URLError(.networkConnectionLost)))
        #expect(message != URLError(.networkConnectionLost).localizedDescription)

        // A new download starts a new retry log.
        let again = Task { try await store.download(spec) }
        _ = try? await again.value
        #expect(store.downloadRetries(for: spec).count == 3)
        #expect(downloader.callCount == 8)
    }

    @Test func offlineFailsAfterOneAttemptWithTheOfflineMessage() async throws {
        let downloader = ScriptedDownloader(root: root) { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let store = try makeStore(downloader)
        await #expect(throws: URLError(.notConnectedToInternet)) { try await store.download(spec) }
        #expect(downloader.callCount == 1)
        #expect(store.downloadRetries(for: spec).isEmpty)
        #expect(
            store.state(for: spec)
                == .failed(message: LiveModelStore.failureMessage(for: URLError(.notConnectedToInternet))))
    }

    @Test func lastErrorDecidesTheMessage() async throws {
        // Wi-Fi drops: connection lost first, then offline on the retry.
        let downloader = ScriptedDownloader(root: root) { call, _, _ in
            throw call == 1 ? URLError(.networkConnectionLost) : URLError(.notConnectedToInternet)
        }
        let store = try makeStore(downloader)
        _ = try? await store.download(spec)
        #expect(downloader.callCount == 2)
        #expect(
            store.state(for: spec)
                == .failed(message: LiveModelStore.failureMessage(for: URLError(.notConnectedToInternet))))
    }

    @Test func cancelDuringBackoffStopsPromptly() async throws {
        let slow = DownloadRetryPolicy(maxRetries: 3, initialDelay: .seconds(60), maxDelay: .seconds(60))
        let downloader = ScriptedDownloader(root: root) { _, snapshot, _ in
            try ScriptedDownloader.write(["config.json"], in: snapshot)
            throw URLError(.timedOut)
        }
        let store = try makeStore(downloader, policy: slow)
        let download = Task { try await store.download(spec) }
        try await waitUntil { store.downloadRetries(for: spec).count == 1 }
        let start = ContinuousClock.now
        store.cancelDownload(spec)
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(store.state(for: spec) == .notDownloaded)
        #expect(downloader.callCount == 1)
        #expect(store.totalBytesOnDisk >= 1000, "finished files are kept")
    }

    @Test func joiningCallerSeesTheRetriedResult() async throws {
        let downloader = ScriptedDownloader(root: root) { call, snapshot, _ in
            if call == 1 { throw URLError(.dnsLookupFailed) }
            try ScriptedDownloader.write(ScriptedDownloader.allFiles, in: snapshot)
        }
        let store = try makeStore(downloader)
        async let first: Void = store.download(spec)
        async let second: Void = store.download(spec)
        _ = try await (first, second)
        #expect(downloader.callCount == 2)
        #expect(store.state(for: spec).isDownloaded)
    }

    @Test func placeholderAndOversizedProgressAreNormalized() async throws {
        let gate = TokenGate()
        let downloader = ScriptedDownloader(root: root) { _, snapshot, progress in
            // HubClient's "already complete" fast path reports a 1-unit total.
            progress(DownloadProgress(completedBytes: 1, totalBytes: 1))
            await gate.wait()
            try ScriptedDownloader.write(ScriptedDownloader.allFiles, in: snapshot)
        }
        let store = try makeStore(downloader)
        let download = Task { try await store.download(spec) }
        try await waitUntil {
            if case .downloading(let fraction, _, _) = store.state(for: spec) { return fraction == 1 }
            return false
        }
        #expect(
            store.state(for: spec)
                == .downloading(progress: 1, bytesReceived: spec.downloadBytes, bytesTotal: spec.downloadBytes))
        gate.open()
        try await download.value

        // More bytes than the total (never shown as more than 100 %).
        let other = ModelCatalog.qwen3_1_7B
        let gate2 = TokenGate()
        let secondRoot = root.appending(path: "second", directoryHint: .isDirectory)
        let overshoot = ScriptedDownloader(root: secondRoot) { _, snapshot, progress in
            progress(DownloadProgress(completedBytes: 5000, totalBytes: 3000))
            await gate2.wait()
            try ScriptedDownloader.write(ScriptedDownloader.allFiles, in: snapshot)
        }
        let store2 = try LiveModelStore(
            catalog: [other], rootDirectory: secondRoot, downloader: overshoot,
            retryPolicy: fast, freeSpace: { _ in nil })
        let download2 = Task { try await store2.download(other) }
        try await waitUntil {
            if case .downloading(let fraction, _, _) = store2.state(for: other) { return fraction == 1 }
            return false
        }
        #expect(
            store2.state(for: other)
                == .downloading(progress: 1, bytesReceived: 3000, bytesTotal: 3000))
        gate2.open()
        try await download2.value
    }

    @Test func failureMessages() {
        let network = LiveModelStore.failureMessage(for: URLError(.timedOut))
        let offline = LiveModelStore.failureMessage(for: URLError(.notConnectedToInternet))
        #expect(network != offline)
        #expect(network.isEmpty == false && offline.isEmpty == false)
        // Wrapped device errors get the same sentence.
        let wrapped = NSError(
            domain: "Wrapper", code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1005)])
        #expect(LiveModelStore.failureMessage(for: wrapped) == network)
        // Errors of this package keep their own text.
        let server = ModelDownloadError.httpStatus(503, detail: "busy")
        #expect(LiveModelStore.failureMessage(for: server) == server.localizedDescription)
        #expect(server.localizedDescription.contains("503"))
        #expect(server.localizedDescription.contains("busy") == false, "server text is not shown")
        let notFound = ModelDownloadError.httpStatus(404, detail: "")
        #expect(notFound.localizedDescription != server.localizedDescription)
        let incomplete = ModelStoreError.incompleteDownload(missing: ["model.safetensors"])
        #expect(LiveModelStore.failureMessage(for: incomplete) == incomplete.localizedDescription)
        let disk = ModelStoreError.insufficientDiskSpace(requiredBytes: 2, availableBytes: 1)
        #expect(LiveModelStore.failureMessage(for: disk) == disk.localizedDescription)
        #expect(LiveModelStore.failureMessage(for: MockDownloadFailure(message: "x")) == "x")
    }
}

@Suite("Snapshot completeness")
struct SnapshotCompletenessTests {
    let directory: URL
    let listing: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "LLMCoreSnapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        directory = base.appending(path: "snapshots/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        listing = base.appending(path: "listing.json")
        let json = """
            {"entries": [
              {"path": ".gitattributes", "type": "file", "size": 1519},
              {"path": "README.md", "type": "file", "size": 900},
              {"path": "config.json", "type": "file", "size": 900, "oid": "a"},
              {"path": "model.safetensors", "type": "file", "size": 968000000},
              {"path": "tokenizer.json", "type": "file", "size": 11000000},
              {"path": "tokenizer_config.json", "type": "file", "size": 9000},
              {"path": "chat_template.jinja", "type": "file"},
              {"path": "nested", "type": "directory"},
              {"path": "nested/extra.json", "type": "file", "size": 10}
            ]}
            """
        try Data(json.utf8).write(to: listing)
    }

    @Test func reportsMissingMatchingFilesOnly() throws {
        try ScriptedDownloader.write(["config.json", "tokenizer.json", "model.safetensors"], in: directory)
        let missing = SnapshotCompleteness.missingFiles(
            listingFile: listing, matching: ModelDownloadPatterns.all, in: directory)
        // README.md / .gitattributes do not match the patterns; `*` matches `/` like fnmatch
        // without flags (HubClient's rule), so nested/extra.json counts.
        #expect(missing == ["chat_template.jinja", "nested/extra.json", "tokenizer_config.json"])
    }

    @Test func completeSnapshotHasNothingMissing() throws {
        try ScriptedDownloader.write(
            ["config.json", "tokenizer.json", "model.safetensors", "tokenizer_config.json",
             "chat_template.jinja"], in: directory)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "nested"), withIntermediateDirectories: true)
        try ScriptedDownloader.write(["nested/extra.json"], in: directory)
        #expect(
            SnapshotCompleteness.missingFiles(
                listingFile: listing, matching: ModelDownloadPatterns.all, in: directory) == [])
    }

    @Test func symlinksAreFollowed() throws {
        // Snapshot files are relative symlinks into blobs/; a dangling one counts as missing.
        let blobs = directory.deletingLastPathComponent().appending(path: "blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try ScriptedDownloader.write(["blob1"], in: blobs)
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(
            atPath: directory.appending(path: "config.json").path, withDestinationPath: "../blobs/blob1")
        try fileManager.createSymbolicLink(
            atPath: directory.appending(path: "tokenizer.json").path, withDestinationPath: "../blobs/gone")
        let missing = try #require(
            SnapshotCompleteness.missingFiles(listingFile: listing, matching: ["config.json", "tokenizer.json"], in: directory))
        #expect(missing == ["tokenizer.json"])
    }

    @Test func unreadableListingSkipsTheCheck() throws {
        let absent = listing.deletingLastPathComponent().appending(path: "absent.json")
        #expect(
            SnapshotCompleteness.missingFiles(
                listingFile: absent, matching: ModelDownloadPatterns.all, in: directory) == nil)
        try Data("not json".utf8).write(to: listing)
        #expect(
            SnapshotCompleteness.missingFiles(
                listingFile: listing, matching: ModelDownloadPatterns.all, in: directory) == nil)
    }
}

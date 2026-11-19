import Foundation
import Observation

/// Written after a download completed and was validated. Its presence is what makes a model
/// "downloaded"; it survives relaunches. Paths are stored relative to the store root because the
/// app container path changes across reinstalls and updates.
struct InstallManifest: Codable, Hashable, Sendable {
    var formatVersion = 1
    var specID: String
    var repoID: String
    var revision: String
    /// Model directory relative to the store root.
    var relativeModelPath: String
    var completedAt: Date
}

/// ``ModelStore`` backed by real files. The download itself is delegated to a
/// ``ModelDownloader`` (the app passes a Hugging Face implementation); everything else — state,
/// disk-space checks, retries, manifests, deletion, disk usage — lives here and is unit-tested.
///
/// Downloads are retried automatically by ``retryPolicy`` when an attempt fails for a transient
/// reason (connection lost, timeout, DNS, HTTP 5xx; see ``DownloadRetryPolicy``). The state
/// stays `.downloading` during retries and its progress never goes backwards. A failure that is
/// finally reported carries a message from ``failureMessage(for:)``.
///
/// Layout under `rootDirectory` (normally `Application Support/Models`, excluded from backup):
/// - `manifests/<spec.id>.json` — completion markers
/// - whatever the downloader uses (the Hugging Face cache lives in `hub/`)
@Observable
@MainActor
public final class LiveModelStore: ModelStore {
    public let catalog: [ModelSpec]
    public let rootDirectory: URL

    public private(set) var states: [String: ModelInstallState] = [:]
    public private(set) var totalBytesOnDisk: Int64 = 0

    /// Extra free space required beyond the remaining download size.
    public static let minimumFreeSpaceMargin: Int64 = 256 * 1024 * 1024

    /// Retries for transient download failures.
    @ObservationIgnored public let retryPolicy: DownloadRetryPolicy

    @ObservationIgnored private let downloader: any ModelDownloader
    @ObservationIgnored private let freeSpace: @Sendable (URL) -> Int64?
    @ObservationIgnored private var downloads: [String: ActiveDownload] = [:]
    @ObservationIgnored private var failures: [String: String] = [:]
    @ObservationIgnored private var retryLog: [String: [DownloadRetryRecord]] = [:]

    private struct ActiveDownload {
        let token: UUID
        let task: Task<URL, Error>
    }

    public init(
        catalog: [ModelSpec] = ModelCatalog.presets,
        rootDirectory: URL,
        downloader: any ModelDownloader,
        retryPolicy: DownloadRetryPolicy = .standard,
        freeSpace: @escaping @Sendable (URL) -> Int64? = { FileUtilities.availableCapacity(at: $0) }
    ) throws {
        for spec in catalog where !Self.isSafeIdentifier(spec.id) {
            throw ModelStoreError.invalidSpec(spec.id)
        }
        self.catalog = catalog
        self.rootDirectory = rootDirectory
        self.downloader = downloader
        self.retryPolicy = retryPolicy
        self.freeSpace = freeSpace
        try FileManager.default.createDirectory(
            at: manifestsDirectory, withIntermediateDirectories: true)
        try FileUtilities.excludeFromBackup(rootDirectory)
        refresh()
        if downloads.isEmpty { downloader.cleanUpTemporaryFiles() }
    }

    // MARK: - ModelStore

    public func state(for spec: ModelSpec) -> ModelInstallState {
        states[spec.id] ?? .notDownloaded
    }

    public func localDirectory(for spec: ModelSpec) -> URL? {
        guard let manifest = validManifest(for: spec) else { return nil }
        return rootDirectory.appending(path: manifest.relativeModelPath, directoryHint: .isDirectory)
    }

    public func availableDiskBytes() -> Int64? {
        freeSpace(rootDirectory)
    }

    public func download(_ spec: ModelSpec) async throws {
        if let active = downloads[spec.id] {
            _ = try await active.task.value
            return
        }
        if validManifest(for: spec) != nil {
            states[spec.id] = .downloaded(bytesOnDisk: bytesOnDisk(for: spec))
            return
        }

        let alreadyOnDisk = bytesOnDisk(for: spec)
        let remaining = max(0, spec.downloadBytes - alreadyOnDisk)
        let required = remaining + max(Self.minimumFreeSpaceMargin, spec.downloadBytes / 20)
        if let available = freeSpace(rootDirectory), available < required {
            let error = ModelStoreError.insufficientDiskSpace(
                requiredBytes: required, availableBytes: available)
            failures[spec.id] = error.localizedDescription
            states[spec.id] = .failed(message: error.localizedDescription)
            throw error
        }

        failures[spec.id] = nil
        retryLog[spec.id] = []
        let token = UUID()
        states[spec.id] = .downloading(
            progress: 0, bytesReceived: 0, bytesTotal: spec.downloadBytes)
        let downloader = self.downloader
        let policy = retryPolicy
        // One closure for every attempt: applyProgress ignores fractions below the current one,
        // so a retry (which starts again from the files already on disk) never moves the bar
        // backwards.
        let report: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.applyProgress(progress, to: spec, token: token)
            }
        }
        let task = Task<URL, Error> {
            try await policy.run(
                onRetry: { [weak self] record in
                    await self?.noteRetry(record, for: spec, token: token)
                },
                { try await downloader.download(spec, progress: report) })
        }
        downloads[spec.id] = ActiveDownload(token: token, task: task)

        do {
            let directory = try await task.value
            try finishInstall(spec, directory: directory)
            downloads[spec.id] = nil
            states[spec.id] = .downloaded(bytesOnDisk: bytesOnDisk(for: spec))
            refreshTotals()
            cleanUpIfIdle()
        } catch {
            if downloads[spec.id]?.token == token { downloads[spec.id] = nil }
            if Self.isCancellation(error) || task.isCancelled {
                failures[spec.id] = nil
                states[spec.id] = .notDownloaded
                refreshTotals()
                cleanUpIfIdle()
                throw CancellationError()
            }
            let message = Self.failureMessage(for: error)
            failures[spec.id] = message
            states[spec.id] = .failed(message: message)
            refreshTotals()
            cleanUpIfIdle()
            throw error  // unchanged, so diagnostics keep its domain and code
        }
    }

    /// Retries of the current or last download of `spec` (empty when none were needed).
    public func downloadRetries(for spec: ModelSpec) -> [DownloadRetryRecord] {
        retryLog[spec.id] ?? []
    }

    /// The localized message shown for a download that finally failed. Network failures get an
    /// actionable sentence (the system's text, e.g. "The network connection was lost.", says
    /// nothing about what to do); other errors keep their own description.
    public nonisolated static func failureMessage(for error: any Error) -> String {
        switch DownloadRetryPolicy.classify(error) {
        case .offline:
            return String(
                localized:
                    "No internet connection. Connect to Wi-Fi or cellular data and try again. Files that already finished downloading are kept.",
                bundle: .module)
        case .transient where error is ModelDownloadError || error is ModelStoreError:
            return error.localizedDescription
        case .transient:
            return String(
                localized:
                    "The download was interrupted by a network problem. Try again: files that already finished downloading are kept.",
                bundle: .module)
        case .cancelled, .permanent:
            return error.localizedDescription
        }
    }

    public func cancelDownload(_ spec: ModelSpec) {
        downloads[spec.id]?.task.cancel()
    }

    public func delete(_ spec: ModelSpec) async throws {
        if let active = downloads[spec.id] {
            active.task.cancel()
            _ = try? await active.task.value
            downloads[spec.id] = nil
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: manifestURL(for: spec))
        for location in downloader.storageLocations(for: spec)
        where fileManager.fileExists(atPath: location.path) {
            try fileManager.removeItem(at: location)
        }
        failures[spec.id] = nil
        states[spec.id] = .notDownloaded
        refreshTotals()
        cleanUpIfIdle()
    }

    // MARK: - State

    /// Re-reads manifests and file sizes from disk.
    public func refresh() {
        for spec in catalog {
            if let active = downloads[spec.id], !active.task.isCancelled {
                continue
            }
            if validManifest(for: spec) != nil {
                states[spec.id] = .downloaded(bytesOnDisk: bytesOnDisk(for: spec))
            } else if let failure = failures[spec.id] {
                states[spec.id] = .failed(message: failure)
            } else {
                states[spec.id] = .notDownloaded
            }
        }
        refreshTotals()
    }

    /// Bytes on disk for one model (complete or partial).
    public func bytesOnDisk(for spec: ModelSpec) -> Int64 {
        downloader.storageLocations(for: spec).reduce(0) {
            $0 + FileUtilities.allocatedSize(of: $1)
        }
    }

    private func refreshTotals() {
        totalBytesOnDisk = catalog.reduce(0) { $0 + bytesOnDisk(for: $1) }
    }

    /// Monotonic: a report below the current fraction (a retry starting over, or a late report
    /// of an earlier attempt) is ignored. Byte counts never exceed the total.
    func applyProgress(_ progress: DownloadProgress, to spec: ModelSpec, token: UUID) {
        guard downloads[spec.id]?.token == token else { return }
        if case .downloading(let previous, _, _) = states[spec.id], progress.fraction < previous {
            return
        }
        // swift-huggingface reports placeholder unit counts (total 1) when it has no byte
        // sizes, e.g. for a snapshot that is already complete; show catalog bytes instead of
        // "1 B of 1 B".
        let total: Int64
        let received: Int64
        if progress.totalBytes > 1 {
            total = progress.totalBytes
            received = min(max(progress.completedBytes, 0), total)
        } else {
            total = spec.downloadBytes
            received = Int64(progress.fraction * Double(total))
        }
        states[spec.id] = .downloading(
            progress: progress.fraction, bytesReceived: received, bytesTotal: total)
    }

    private func noteRetry(_ record: DownloadRetryRecord, for spec: ModelSpec, token: UUID) {
        guard downloads[spec.id]?.token == token else { return }
        retryLog[spec.id, default: []].append(record)
    }

    private func cleanUpIfIdle() {
        if downloads.isEmpty { downloader.cleanUpTemporaryFiles() }
    }

    // MARK: - Manifests

    private var manifestsDirectory: URL {
        rootDirectory.appending(path: "manifests", directoryHint: .isDirectory)
    }

    private func manifestURL(for spec: ModelSpec) -> URL {
        manifestsDirectory.appending(path: "\(spec.id).json", directoryHint: .notDirectory)
    }

    /// The manifest, if present, matching the spec, and its files are still there.
    private func validManifest(for spec: ModelSpec) -> InstallManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: spec)),
            let manifest = try? Self.manifestDecoder.decode(InstallManifest.self, from: data),
            manifest.specID == spec.id, manifest.repoID == spec.repoID,
            manifest.revision == spec.revision
        else { return nil }
        let directory = rootDirectory.appending(
            path: manifest.relativeModelPath, directoryHint: .isDirectory)
        guard Self.missingRequiredFiles(in: directory).isEmpty else { return nil }
        return manifest
    }

    private func finishInstall(_ spec: ModelSpec, directory: URL) throws {
        let missing = Self.missingRequiredFiles(in: directory)
        guard missing.isEmpty else { throw ModelStoreError.incompleteDownload(missing: missing) }
        guard let relative = FileUtilities.relativePath(of: directory, inside: rootDirectory) else {
            throw ModelStoreError.invalidSpec("download directory is outside the store")
        }
        let manifest = InstallManifest(
            specID: spec.id, repoID: spec.repoID, revision: spec.revision,
            relativeModelPath: relative, completedAt: Date())
        try Self.manifestEncoder.encode(manifest).write(to: manifestURL(for: spec), options: .atomic)
    }

    nonisolated static let manifestEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated static let manifestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Files every MLX LLM directory needs. `*.safetensors` means "at least one".
    nonisolated static func missingRequiredFiles(in directory: URL) -> [String] {
        let fileManager = FileManager.default
        var missing: [String] = []
        for name in ["config.json", "tokenizer.json"]
        where !fileManager.fileExists(atPath: directory.appending(path: name).path) {
            missing.append(name)
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        if !contents.contains(where: { $0.hasSuffix(".safetensors") }) {
            missing.append("*.safetensors")
        }
        return missing
    }

    nonisolated static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100
            && id.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-"
                    || $0 == "_"
            }
            && !id.hasPrefix(".")
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

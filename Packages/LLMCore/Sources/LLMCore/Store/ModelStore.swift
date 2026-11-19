import Foundation
import Observation

/// Per-model install state.
public enum ModelInstallState: Hashable, Sendable {
    case notDownloaded
    /// `progress` is 0...1; byte counts are those reported by the downloader.
    case downloading(progress: Double, bytesReceived: Int64, bytesTotal: Int64)
    /// Completed (a manifest was written after a successful download).
    case downloaded(bytesOnDisk: Int64)
    /// The last download attempt failed; `message` is localized.
    case failed(message: String)

    public var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Download progress reported by a ``ModelDownloader``.
public struct DownloadProgress: Hashable, Sendable {
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0
    }
}

/// Downloads, tracks and deletes model files.
///
/// Implementations: ``LiveModelStore`` (real files; the network part is a ``ModelDownloader``)
/// and ``MockModelStore`` (simulated, for the simulator and tests).
@MainActor
public protocol ModelStore: AnyObject, Observable {
    /// Models this store manages.
    var catalog: [ModelSpec] { get }

    func state(for spec: ModelSpec) -> ModelInstallState

    /// Downloads `spec`. Returns when the model is installed; throws on failure, on
    /// insufficient disk space, or `CancellationError` after ``cancelDownload(_:)``.
    /// Calling it again while a download is running joins that download.
    /// ``LiveModelStore`` retries transient network failures itself before reporting one.
    func download(_ spec: ModelSpec) async throws

    /// Cancels a running download. Files already completed are kept (the next download skips
    /// them); the state returns to `.notDownloaded`.
    func cancelDownload(_ spec: ModelSpec)

    /// Removes all files of `spec`, including partial downloads.
    func delete(_ spec: ModelSpec) async throws

    /// Local directory to load from, only when the model is downloaded.
    func localDirectory(for spec: ModelSpec) -> URL?

    /// Bytes used on disk by all models (including partial downloads).
    var totalBytesOnDisk: Int64 { get }

    /// Free space on the volume that holds the models (`nil` if unknown).
    func availableDiskBytes() -> Int64?
}

/// Errors thrown by model stores.
public enum ModelStoreError: LocalizedError, Equatable, Sendable {
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case incompleteDownload(missing: [String])
    case notDownloaded(modelName: String)
    case invalidSpec(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            let requiredText = ByteFormatting.string(required)
            let availableText = ByteFormatting.string(available)
            return String(
                localized:
                    "Not enough free storage. This download needs about \(requiredText), but only \(availableText) is free.",
                bundle: .module)
        case .incompleteDownload(let missing):
            let list = missing.joined(separator: ", ")
            return String(
                localized: "The download is incomplete (missing: \(list)). Please try again.",
                bundle: .module)
        case .notDownloaded(let name):
            return String(localized: "\(name) is not downloaded yet.", bundle: .module)
        case .invalidSpec(let detail):
            return String(localized: "Invalid model entry: \(detail)", bundle: .module)
        }
    }
}

/// The network part of ``LiveModelStore``. The app's implementation uses swift-huggingface's
/// `HubClient` with a cache under Application Support.
public protocol ModelDownloader: Sendable {
    /// Downloads (or completes) the files of `spec` and returns the directory that contains
    /// them. Must honour task cancellation. `progress` may be called on any thread.
    /// One call is one attempt: it should throw network errors as received (their `NSError`
    /// domain and code are what ``DownloadRetryPolicy`` classifies) and keep completed files,
    /// so that calling it again continues the download.
    func download(
        _ spec: ModelSpec, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL

    /// Every file-system location that holds data for `spec` (removed by delete, measured for
    /// disk usage).
    func storageLocations(for spec: ModelSpec) -> [URL]

    /// Called when no download is running, to remove leftovers (e.g. temporary files).
    func cleanUpTemporaryFiles()
}

extension ModelDownloader {
    public func cleanUpTemporaryFiles() {}
}

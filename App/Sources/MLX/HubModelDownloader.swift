import Foundation
import HuggingFace
import LLMCore

/// ``ModelDownloader`` backed by swift-huggingface's `HubClient`.
///
/// - Files go into a Python-compatible Hugging Face cache under `cacheDirectory`
///   (`Application Support/Models/hub`), not the library default `Library/Caches/huggingface`,
///   which iOS may purge.
/// - The returned directory is `<cache>/models--org--name/snapshots/<commit>`; its files are
///   relative symlinks into `blobs/`, which both the weight loader and the tokenizer follow.
/// - Resume is per file: completed files are kept and skipped on the next attempt, but a file
///   that was interrupted restarts from zero (HubClient only resumes from `.incomplete` blobs it
///   never writes itself on cancellation).
/// - With a pinned commit hash, HubClient also saves the snapshot file list, so a later call for
///   an already complete snapshot returns without any network request.
/// - Requests carry no token (`bearerToken: nil`) and a `User-Agent` of just the app name and
///   version (``UserAgent/current``, read from the bundle).
/// - The session keeps no cookies and no URL cache: `HubClient` takes the `URLSession` as an
///   init parameter and, on Apple platforms, uses that one session for every request (file
///   listing, HEAD preflight, downloads; `HubClient.swift` / `HubClient+Files.swift` in
///   swift-huggingface 0.9.0).
/// - One call is one attempt; `LiveModelStore` retries transient failures
///   (`DownloadRetryPolicy`). Network failures surface as the `URLError` that `URLSession`
///   threw (HubClient rethrows them unwrapped); HubClient's own `HTTPClientError` is not a
///   `LocalizedError`, so it is translated into `ModelDownloadError` (HTTP status kept, so 5xx
///   is retried and 404 is not).
/// - When listing the repository fails and a partial snapshot is on disk, HubClient returns that
///   partial snapshot instead of the error (`HubClient+Files.swift` 1271–1287). `download`
///   detects this with the file list HubClient saved for the commit, lists again to surface the
///   real error (offline, connection lost…), and otherwise reports the snapshot as incomplete
///   (retried).
final class HubModelDownloader: ModelDownloader {
    let cache: HubCache
    private let client: HubClient

    init(cacheDirectory: URL) {
        cache = HubCache(cacheDirectory: cacheDirectory)
        client = HubClient(
            session: URLSession(configuration: Self.sessionConfiguration()),
            host: HubClient.defaultHost,
            userAgent: UserAgent.current,
            bearerToken: nil,
            cache: cache)
    }

    /// Ephemeral-style configuration: no cookie storage (nothing stored, nothing resent), no
    /// URL cache.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return configuration
    }

    func download(
        _ spec: ModelSpec, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: spec.repoID) else {
            throw ModelStoreError.invalidSpec(spec.repoID)
        }
        let directory: URL
        do {
            directory = try await client.downloadSnapshot(
                of: repo,
                kind: .model,
                revision: spec.revision,
                matching: ModelDownloadPatterns.all,
                progressHandler: { @MainActor value in
                    progress(
                        DownloadProgress(
                            completedBytes: value.completedUnitCount,
                            totalBytes: value.totalUnitCount))
                })
        } catch let error as HTTPClientError {
            throw Self.translate(error)
        }

        // HubClient saves the commit's file list before downloading; without it (nil) the check
        // is skipped, so it can never reject a good snapshot.
        let listing = cache.metadataDirectory(repo: repo, kind: .model)
            .appending(path: "\(spec.revision).json", directoryHint: .notDirectory)
        guard
            let missing = SnapshotCompleteness.missingFiles(
                listingFile: listing, matching: ModelDownloadPatterns.all, in: directory),
            !missing.isEmpty
        else { return directory }

        // A partial snapshot came back, so HubClient's listing failed (or this task was
        // cancelled while listing). List again to surface the real error.
        try Task.checkCancellation()
        do {
            _ = try await client.listFiles(in: repo, kind: .model, revision: spec.revision)
        } catch let error as HTTPClientError {
            throw Self.translate(error)
        }
        throw ModelStoreError.incompleteDownload(missing: Array(missing.prefix(5)))
    }

    /// `HTTPClientError` is not a `LocalizedError` (its `localizedDescription` is "The operation
    /// couldn't be completed. (HuggingFace.HTTPClientError error 1.)").
    static func translate(_ error: HTTPClientError) -> ModelDownloadError {
        switch error {
        case .responseError(let response, let detail):
            .httpStatus(response.statusCode, detail: String(detail.prefix(500)))
        case .decodingError, .requestError, .unexpectedError:
            .library(String(error.description.prefix(500)))
        }
    }

    func storageLocations(for spec: ModelSpec) -> [URL] {
        guard let repo = Repo.ID(rawValue: spec.repoID) else { return [] }
        let repoDirectory = cache.repoDirectory(repo: repo, kind: .model)
        return [
            repoDirectory,
            cache.metadataDirectory(repo: repo, kind: .model),
            cache.lockPath(for: repoDirectory),
        ]
    }

    /// `URLSession.download(for:)` (async) leaves its `CFNetworkDownload_*.tmp` file in place,
    /// and HubClient copies it into the cache without deleting it. On APFS the copy is a clone,
    /// so the leftover would keep a deleted model's blocks allocated. Called only when no
    /// download is running.
    func cleanUpTemporaryFiles() {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: temporary, includingPropertiesForKeys: nil)
        else { return }
        for file in files
        where file.lastPathComponent.hasPrefix("CFNetworkDownload_") && file.pathExtension == "tmp" {
            try? fileManager.removeItem(at: file)
        }
    }
}

import Foundation

/// How a failed download attempt is treated by ``DownloadRetryPolicy``.
public enum DownloadFailureKind: String, Hashable, Sendable, Codable {
    /// The download was cancelled (user, deletion, the task went away). Never retried.
    case cancelled
    /// The device has no usable network path (`notConnectedToInternet`, cellular data not
    /// allowed, roaming off). Not retried: URLSession fails these immediately
    /// (`waitsForConnectivity` is off), a few seconds of backoff rarely fixes them, and the user
    /// has to act (turn on Wi-Fi, allow cellular data). Failing fast shows the message sooner.
    case offline
    /// A network blip or a temporary server problem (connection lost, timeout, DNS, HTTP 5xx…).
    /// Retried with backoff.
    case transient
    /// Anything else (disk full, HTTP 404, TLS trust failure…). Not retried.
    case permanent
}

/// Retries downloads that failed for a plausibly transient reason.
///
/// Evidence (first device run, 2026-11-18): the first download of Qwen3 1.7B failed after 5 s
/// with `NSURLErrorDomain -1005` ("The network connection was lost") just as the large
/// `model.safetensors` started on the CDN; an immediate second attempt downloaded all 982 MB in
/// 11 s. Files that completed are kept by the downloader and skipped on the next attempt, so a
/// retry is just calling it again.
///
/// Rules:
/// - Cancellation always wins: if the task is cancelled, the attempt's error is replaced by
///   `CancellationError` and nothing is retried; the backoff sleep is cancellation-aware.
/// - Only ``DownloadFailureKind/transient`` failures are retried, at most ``maxRetries`` times,
///   waiting ``delay(beforeRetry:)`` before each retry.
public struct DownloadRetryPolicy: Hashable, Sendable {
    /// Retries after the first attempt (0 = no retry).
    public var maxRetries: Int
    /// Wait before the first retry; doubles for each further retry.
    public var initialDelay: Duration
    /// Upper bound for one wait.
    public var maxDelay: Duration

    public init(maxRetries: Int, initialDelay: Duration, maxDelay: Duration) {
        self.maxRetries = max(0, maxRetries)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    /// 3 retries after 1 s, 2 s and 4 s (at most 7 s of waiting in total).
    public static let standard = DownloadRetryPolicy(
        maxRetries: 3, initialDelay: .seconds(1), maxDelay: .seconds(8))

    /// No retries.
    public static let none = DownloadRetryPolicy(
        maxRetries: 0, initialDelay: .zero, maxDelay: .zero)

    /// Wait before retry number `retry` (1-based): `initialDelay · 2^(retry-1)`, capped at
    /// ``maxDelay``.
    public func delay(beforeRetry retry: Int) -> Duration {
        var delay = initialDelay
        var step = 1
        while step < retry, delay < maxDelay {
            delay = delay * 2
            step += 1
        }
        return min(delay, maxDelay)
    }

    /// Runs `operation`, retrying transient failures.
    ///
    /// - Parameters:
    ///   - sleep: waits between attempts (tests inject their own); must throw when cancelled.
    ///   - onRetry: called before each wait with what failed.
    ///   - operation: one attempt.
    /// - Returns: the first successful result.
    /// - Throws: `CancellationError` when the task is cancelled; otherwise the last attempt's
    ///   error, unchanged (so its domain and code stay visible to diagnostics).
    public func run<T: Sendable>(
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onRetry: @Sendable (DownloadRetryRecord) async -> Void = { _ in },
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard Self.classify(error) == .transient, retries < maxRetries else { throw error }
                retries += 1
                let delay = delay(beforeRetry: retries)
                await onRetry(DownloadRetryRecord(retry: retries, delay: delay, error: error))
                try await sleep(delay)
            }
        }
    }

    // MARK: - Classification

    /// Classifies a download error. Errors of this package (``ModelDownloadError``,
    /// ``ModelStoreError``) are classified by case; everything else through its `NSError`
    /// domain and code, walking the `NSUnderlyingError` chain (first match wins).
    public static func classify(_ error: any Error) -> DownloadFailureKind {
        if error is CancellationError { return .cancelled }
        if let error = error as? ModelDownloadError {
            switch error {
            case .httpStatus(let status, _):
                return isTransientHTTPStatus(status) ? .transient : .permanent
            case .library:
                return .permanent
            }
        }
        if let error = error as? ModelStoreError {
            switch error {
            // The downloader returned a snapshot with files missing. With swift-huggingface
            // this happens when listing the repository failed and it fell back to the partial
            // snapshot on disk; another attempt lists again.
            case .incompleteDownload: return .transient
            case .insufficientDiskSpace, .notDownloaded, .invalidSpec: return .permanent
            }
        }
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if let kind = classify(domain: nsError.domain, code: nsError.code) { return kind }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return .permanent
    }

    /// `nil` when the code says nothing decisive (keep walking the underlying errors).
    static func classify(domain: String, code: Int) -> DownloadFailureKind? {
        switch domain {
        case NSURLErrorDomain, "kCFErrorDomainCFNetwork":
            // CFNetwork's kCFURLError* codes have the same values as NSURLError*.
            switch code {
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
                NSURLErrorInternationalRoamingOff:
                return .offline
            case NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed:
                return .transient
            default:
                return nil
            }
        case NSPOSIXErrorDomain:
            let transient: Set<POSIXErrorCode> = [
                .ENETDOWN, .ENETUNREACH, .ENETRESET, .ECONNABORTED, .ECONNRESET, .ETIMEDOUT,
            ]
            if let posix = POSIXErrorCode(rawValue: Int32(truncatingIfNeeded: code)),
                transient.contains(posix)
            {
                return .transient
            }
            return nil
        default:
            return nil
        }
    }

    /// 408 Request Timeout, 429 Too Many Requests and 5xx.
    static func isTransientHTTPStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }
}

/// One retry, for diagnostics (the self-test reports them).
public struct DownloadRetryRecord: Hashable, Sendable, Codable {
    /// 1-based retry number.
    public var retry: Int
    /// Seconds waited before the retry.
    public var delaySeconds: Double
    /// `NSError` domain and code of the failure that caused the retry.
    public var errorDomain: String
    public var errorCode: Int
    /// `localizedDescription` of that failure.
    public var errorMessage: String

    public init(retry: Int, delay: Duration, error: any Error) {
        let nsError = error as NSError
        self.retry = retry
        self.delaySeconds = delay.seconds
        self.errorDomain = nsError.domain
        self.errorCode = nsError.code
        self.errorMessage = error.localizedDescription
    }
}

/// Failures reported by a ``ModelDownloader`` that its library does not describe well. The
/// app's Hugging Face downloader translates the library's HTTP errors into these, because the
/// library's error type is not a `LocalizedError`.
public enum ModelDownloadError: LocalizedError, Equatable, Sendable {
    /// The server answered with an HTTP error status. `detail` is the server's text (not shown
    /// to users; kept for diagnostics).
    case httpStatus(Int, detail: String)
    /// Any other failure inside the download library (not localized; shown as detail).
    case library(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status, _):
            if DownloadRetryPolicy.isTransientHTTPStatus(status) {
                return String(
                    localized:
                        "The download server is having trouble (HTTP \(status)). Try again later.",
                    bundle: .module)
            }
            return String(
                localized: "The download server refused the request (HTTP \(status)).",
                bundle: .module)
        case .library(let detail):
            return String(localized: "The download failed: \(detail)", bundle: .module)
        }
    }
}

/// Checks a downloaded snapshot against the file list the download library saved for it.
///
/// swift-huggingface 0.9.0 answers a failed repository listing by returning the snapshot that is
/// already on disk, even a partial one (`HubClient.downloadSnapshot`, `HubClient+Files.swift`
/// lines 1271–1287, via `cachedSnapshotPathForLocalFilesOnly`, which accepts a snapshot when any
/// matching file exists). Without this check a partial snapshot (say, `config.json` and
/// `model.safetensors` but no `tokenizer_config.json`) could pass the three-file check and be
/// installed. The listing is the JSON the library writes before downloading a pinned commit
/// (`<cache>/.metadata/models--org--name/<commit>.json`, its private `CachedSnapshotMetadata`):
/// `{"entries": [{"path": "config.json", "type": "file", …}, …]}`.
public enum SnapshotCompleteness {
    /// Paths listed in `listingFile` that match one of `patterns` (`fnmatch` without flags, the
    /// library's own rule, so `*` also matches `/`) and are missing under `directory`; a path is
    /// present when `fileExists` is true after following symlinks.
    ///
    /// Returns `nil` when the listing is missing or unreadable: callers then skip the check, so
    /// it can never reject a good snapshot.
    public static func missingFiles(
        listingFile: URL, matching patterns: [String], in directory: URL
    ) -> [String]? {
        struct Listing: Decodable {
            struct Entry: Decodable {
                let path: String
                let type: String?
            }
            let entries: [Entry]
        }
        guard let data = try? Data(contentsOf: listingFile),
            let listing = try? JSONDecoder().decode(Listing.self, from: data)
        else { return nil }
        let fileManager = FileManager.default
        return listing.entries
            .filter { $0.type != "directory" }
            .map(\.path)
            .filter { path in patterns.contains { fnmatch($0, path, 0) == 0 } }
            .filter { !fileManager.fileExists(atPath: directory.appending(path: $0).path) }
            .sorted()
    }
}

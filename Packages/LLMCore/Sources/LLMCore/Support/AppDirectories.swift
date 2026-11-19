import Foundation

/// Where the app keeps its files.
///
/// Models live in `Application Support/Models` (never `Caches`, which iOS may purge) and that
/// directory is excluded from iCloud/iTunes backup. The conversation lives in
/// `Application Support/Conversations` (small user data; backed up normally).
public enum AppDirectories {

    public static func applicationSupport() throws -> URL {
        let url = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        return url
    }

    /// `Application Support/Models`, created and excluded from backup.
    public static func modelsRoot() throws -> URL {
        let url = try applicationSupport().appending(path: "Models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileUtilities.excludeFromBackup(url)
        return url
    }

    /// `Application Support/Conversations/current.json`.
    public static func currentConversationFile() throws -> URL {
        let directory = try applicationSupport().appending(
            path: "Conversations", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "current.json", directoryHint: .notDirectory)
    }
}

/// File-system helpers used by the stores.
public enum FileUtilities {

    /// Sets `isExcludedFromBackup` (applies to the whole directory tree).
    public static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
            == true
    }

    /// Free space for important (user-initiated) data on the volume holding `url`.
    public static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Allocated bytes of regular files under `url` (symlinks are not followed or counted, so
    /// Hugging Face snapshot links do not double-count their blobs).
    public static func allocatedSize(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey,
        ]
        func size(of file: URL) -> Int64 {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                values.isSymbolicLink != true, values.isRegularFile == true
            else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard isDirectory.boolValue else { return size(of: url) }
        guard
            let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += size(of: file)
        }
        return total
    }

    /// Path of `url` relative to `base`, comparing resolved paths (handles `/private/var` vs
    /// `/var`). `nil` if `url` is not inside `base`.
    public static func relativePath(of url: URL, inside base: URL) -> String? {
        let basePath = base.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

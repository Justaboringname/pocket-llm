import Foundation

/// Saves and restores the current conversation.
public protocol ConversationPersisting: Sendable {
    func load() throws -> ConversationSnapshot?
    func save(_ snapshot: ConversationSnapshot) throws
    func delete() throws
}

/// JSON file persistence (atomic writes). The default location is
/// ``AppDirectories/currentConversationFile()`` in Application Support.
public struct FileConversationStore: ConversationPersisting {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> ConversationSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode(ConversationSnapshot.self, from: data)
    }

    public func save(_ snapshot: ConversationSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Dates use the default (seconds as Double) so they round-trip exactly.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        JSONDecoder()
    }()
}

/// In-memory persistence (previews, tests).
public final class InMemoryConversationStore: ConversationPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: ConversationSnapshot?
    public private(set) var saveCount = 0

    public init(snapshot: ConversationSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func load() throws -> ConversationSnapshot? {
        lock.withLock { snapshot }
    }

    public func save(_ snapshot: ConversationSnapshot) throws {
        lock.withLock {
            self.snapshot = snapshot
            saveCount += 1
        }
    }

    public func delete() throws {
        lock.withLock { snapshot = nil }
    }
}

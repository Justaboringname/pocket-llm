import Foundation
import Synchronization

/// Bookkeeping shared by engine implementations so that generations are serialized and can be
/// stopped and awaited.
///
/// ``makeStream(_:)`` creates the stream returned by ``InferenceEngine/generate(_:options:)``:
/// - any earlier generation is cancelled, and the new one starts only after the earlier ones
///   have fully finished (so GPU work never overlaps);
/// - the stream's termination (consumer cancelled or dropped it) cancels the driver task;
/// - the driver is tracked until it returns, so ``cancelAllAndWait()`` / ``waitForAll()`` can
///   tell when all GPU work is done.
///
/// The `operation` receives the continuation and must finish it (normally or by throwing). It
/// runs in a task that is cancelled on stop; it should react by stopping its producer and
/// still yield a final `.finished` event when it can.
public final class GenerationTaskRegistry: Sendable {
    public typealias Continuation = AsyncThrowingStream<GenerationEvent, Error>.Continuation

    private let tasks = Mutex<[UUID: Task<Void, Never>]>([:])

    public init() {}

    /// Whether a generation is registered (running or waiting to start).
    public var isBusy: Bool {
        tasks.withLock { !$0.isEmpty }
    }

    public func makeStream(
        _ operation: @escaping @Sendable (Continuation) async -> Void
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        let id = UUID()

        let driver: Task<Void, Never> = tasks.withLock { registered in
            let earlier = Array(registered.values)
            for task in earlier { task.cancel() }

            let task = Task {
                for task in earlier { await task.value }
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else {
                    await operation(continuation)
                    // Defensive: operations are expected to finish the stream themselves.
                    continuation.finish()
                }
                self.remove(id)
            }
            registered[id] = task
            return task
        }

        continuation.onTermination = { _ in
            driver.cancel()
        }
        return stream
    }

    /// Cancels every registered generation without waiting.
    public func cancelAll() {
        tasks.withLock { registered in
            for task in registered.values { task.cancel() }
        }
    }

    /// Waits for every generation registered at the time of the call to finish.
    public func waitForAll() async {
        let snapshot = tasks.withLock { Array($0.values) }
        for task in snapshot { await task.value }
    }

    /// Cancels all generations and waits for them to finish.
    public func cancelAllAndWait() async {
        cancelAll()
        await waitForAll()
    }

    private func remove(_ id: UUID) {
        _ = tasks.withLock { $0.removeValue(forKey: id) }
    }
}

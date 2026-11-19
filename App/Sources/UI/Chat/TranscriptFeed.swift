import Foundation
import LLMCore
import Observation

/// A throttled copy of ``ChatViewModel/messages`` for the transcript.
///
/// The view model changes `messages` for every streamed fragment. Reading it directly from the
/// transcript would invalidate the whole message list on every token; instead this copy is
/// refreshed at most ~20 times per second (the first change after a quiet period is applied
/// immediately, so sending feels instant). Rows are `Equatable`, so only the row whose message
/// actually changed — the streaming one — re-renders.
@Observable
@MainActor
final class TranscriptFeed {
    private(set) var messages: [ChatMessage]
    /// Separate from `messages` so views that only care about emptiness do not re-render on
    /// every update (assigned only when it changes).
    private(set) var hasMessages = false

    @ObservationIgnored private let chat: ChatViewModel
    @ObservationIgnored private var lastApplied = Date.distantPast
    @ObservationIgnored private var pending = false
    @ObservationIgnored private let interval: TimeInterval = 0.05

    init(chat: ChatViewModel) {
        self.chat = chat
        self.messages = []
        self.messages = trackMessages()
        self.hasMessages = !messages.isEmpty
    }

    /// Reads `chat.messages` and asks to be told (once) about the next change.
    private func trackMessages() -> [ChatMessage] {
        withObservationTracking {
            chat.messages
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.schedule() }
        }
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        let wait = interval - Date().timeIntervalSince(lastApplied)
        Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self?.apply()
        }
    }

    private func apply() {
        pending = false
        lastApplied = Date()
        let current = trackMessages()
        if current != messages {
            messages = current
        }
        if hasMessages == current.isEmpty {
            hasMessages = !current.isEmpty
        }
    }
}

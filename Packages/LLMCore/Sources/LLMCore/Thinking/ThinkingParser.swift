import Foundation

/// A piece of model output classified by ``ThinkingParser``.
public enum ThinkingSegment: Hashable, Sendable {
    /// Text inside the `<think>` block.
    case thinking(String)
    /// Visible answer text.
    case answer(String)
    /// A bare `</think>` arrived while no `<think>` had been seen (templates that open the
    /// thinking block inside the prompt). Everything emitted as answer so far — plus the text
    /// right before the tag — is reclassified as thinking. The payload is the full thinking text
    /// after the move; consumers that track deltas must clear their answer text.
    case answerMovedToThinking(String)
}

/// Incrementally splits streamed model output into thinking and answer text.
///
/// - Recognises `<think>` only at the very start of the output (leading whitespace allowed).
///   A `<think>` later in an answer is treated as ordinary text.
/// - Tags may be split across chunks in any way; a possible partial tag at the end of a chunk is
///   held back until the next chunk (or ``finish()``) resolves it.
/// - An unterminated thinking block (e.g. the token limit was hit) is flushed by ``finish()``
///   and reported by ``isThinkingUnterminated``.
/// - Leading whitespace of both the thinking and the answer text is dropped, and whitespace right
///   before `</think>` is dropped, so the accumulated texts are display-ready.
///
/// ``thinkingText`` and ``answerText`` always equal the concatenation of the emitted deltas
/// (taking ``ThinkingSegment/answerMovedToThinking(_:)`` into account), so callers can either
/// apply deltas or just read the accumulated values.
public struct ThinkingParser: Sendable {
    public static let openTag = "<think>"
    public static let closeTag = "</think>"

    public enum Phase: Hashable, Sendable {
        /// Waiting to see whether the output starts with `<think>`.
        case detecting
        case thinking
        case answering
    }

    public private(set) var phase: Phase
    public private(set) var thinkingText = ""
    public private(set) var answerText = ""
    /// A thinking block was opened (explicitly, or implicitly by a bare `</think>`).
    public private(set) var hasThinkingBlock: Bool
    /// The thinking block was closed by `</think>`.
    public private(set) var isThinkingClosed = false
    public private(set) var isFinished = false

    private var buffer = ""
    /// Whether a bare `</think>` (no `<think>` seen) still reclassifies earlier text.
    private var watchesImplicitClose = true

    /// - Parameter startsInsideThinking: set when the prompt template already opened the
    ///   `<think>` block, so output begins with reasoning and only contains `</think>`.
    public init(startsInsideThinking: Bool = false) {
        phase = startsInsideThinking ? .thinking : .detecting
        hasThinkingBlock = startsInsideThinking
    }

    /// The thinking block was opened but never closed.
    public var isThinkingUnterminated: Bool { hasThinkingBlock && !isThinkingClosed }

    /// Feeds the next chunk of model output; returns the newly classified segments.
    public mutating func feed(_ chunk: String) -> [ThinkingSegment] {
        guard !isFinished else { return [] }
        buffer += chunk
        var segments: [ThinkingSegment] = []
        process(final: false, into: &segments)
        return segments
    }

    /// Flushes any held-back text. Call once when the stream ends.
    public mutating func finish() -> [ThinkingSegment] {
        guard !isFinished else { return [] }
        var segments: [ThinkingSegment] = []
        process(final: true, into: &segments)
        isFinished = true
        return segments
    }

    /// Convenience: parse a complete string.
    public static func split(_ text: String) -> (thinking: String, answer: String) {
        var parser = ThinkingParser()
        _ = parser.feed(text)
        _ = parser.finish()
        return (parser.thinkingText, parser.answerText)
    }

    // MARK: - Implementation

    private mutating func process(final: Bool, into segments: inout [ThinkingSegment]) {
        while true {
            switch phase {
            case .detecting:
                let trimmed = buffer.drop(while: \.isWhitespace)
                if trimmed.hasPrefix(Self.openTag) {
                    buffer = String(trimmed.dropFirst(Self.openTag.count))
                    phase = .thinking
                    hasThinkingBlock = true
                    continue
                }
                if !final, Self.openTag.hasPrefix(trimmed) {
                    // Empty, whitespace only, or a partial "<think": wait for more.
                    return
                }
                buffer = String(trimmed)
                phase = .answering
                continue

            case .thinking:
                if thinkingText.isEmpty {
                    buffer = String(buffer.drop(while: \.isWhitespace))
                }
                if let range = buffer.range(of: Self.closeTag) {
                    emitThinking(Self.trimmingTrailingWhitespace(buffer[..<range.lowerBound]), &segments)
                    buffer = String(buffer[range.upperBound...])
                    isThinkingClosed = true
                    phase = .answering
                    continue
                }
                if final {
                    emitThinking(Self.trimmingTrailingWhitespace(buffer[...]), &segments)
                    buffer = ""
                    return
                }
                // Hold back a possible partial close tag and the whitespace before it (which is
                // dropped if the tag follows).
                var end = buffer.index(
                    buffer.endIndex,
                    offsetBy: -Self.partialSuffixLength(of: buffer, matching: Self.closeTag))
                while end > buffer.startIndex, buffer[buffer.index(before: end)].isWhitespace {
                    end = buffer.index(before: end)
                }
                emitThinking(String(buffer[..<end]), &segments)
                buffer = String(buffer[end...])
                return

            case .answering:
                if answerText.isEmpty {
                    buffer = String(buffer.drop(while: \.isWhitespace))
                }
                if !hasThinkingBlock, !watchesImplicitClose {
                    // fallthrough to plain answer handling below
                } else if !hasThinkingBlock {
                    // The window includes the end of the emitted answer so a literal "<think>"
                    // split across chunks is still seen.
                    let window = String(answerText.suffix(Self.openTag.count - 1)) + buffer
                    if let open = window.range(of: Self.openTag),
                        window.range(of: Self.closeTag).map({ open.lowerBound < $0.lowerBound })
                            ?? true
                    {
                        // A literal "<think>" in the answer: a later "</think>" belongs to it,
                        // so stop treating a bare close tag as the end of hidden reasoning.
                        watchesImplicitClose = false
                        continue
                    }
                    if let range = buffer.range(of: Self.closeTag) {
                        // Implicitly opened thinking block: everything so far was reasoning.
                        let moved = Self.trimmingTrailingWhitespace(
                            (answerText + buffer[..<range.lowerBound])[...])
                        let movedTrimmed = String(moved.drop(while: \.isWhitespace))
                        thinkingText = movedTrimmed
                        answerText = ""
                        hasThinkingBlock = true
                        isThinkingClosed = true
                        segments.append(.answerMovedToThinking(movedTrimmed))
                        buffer = String(buffer[range.upperBound...])
                        continue
                    }
                    if !final {
                        let end = buffer.index(
                            buffer.endIndex,
                            offsetBy: -Self.partialSuffixLength(of: buffer, matching: Self.closeTag))
                        emitAnswer(String(buffer[..<end]), &segments)
                        buffer = String(buffer[end...])
                        return
                    }
                }
                emitAnswer(buffer, &segments)
                buffer = ""
                return
            }
        }
    }

    private mutating func emitThinking(_ text: String, _ segments: inout [ThinkingSegment]) {
        guard !text.isEmpty else { return }
        thinkingText += text
        segments.append(.thinking(text))
    }

    private mutating func emitAnswer(_ text: String, _ segments: inout [ThinkingSegment]) {
        guard !text.isEmpty else { return }
        answerText += text
        segments.append(.answer(text))
    }

    /// Length (in characters) of the longest proper prefix of `tag` that `text` ends with.
    static func partialSuffixLength(of text: String, matching tag: String) -> Int {
        let maxLength = min(tag.count - 1, text.count)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1)
        where text.hasSuffix(tag.prefix(length)) {
            return length
        }
        return 0
    }

    static func trimmingTrailingWhitespace(_ text: Substring) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }
}

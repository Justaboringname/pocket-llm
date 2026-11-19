import Testing

@testable import LLMCore

@Suite("ThinkingParser")
struct ThinkingParserTests {

    /// Feeds `chunks`, then finishes; returns the parser and the concatenated deltas.
    private func run(_ chunks: [String], startsInsideThinking: Bool = false)
        -> (parser: ThinkingParser, thinking: String, answer: String)
    {
        var parser = ThinkingParser(startsInsideThinking: startsInsideThinking)
        var thinking = ""
        var answer = ""
        func apply(_ segments: [ThinkingSegment]) {
            for segment in segments {
                switch segment {
                case .thinking(let text): thinking += text
                case .answer(let text): answer += text
                case .answerMovedToThinking(let all):
                    thinking = all
                    answer = ""
                }
            }
        }
        for chunk in chunks { apply(parser.feed(chunk)) }
        apply(parser.finish())
        return (parser, thinking, answer)
    }

    /// Every way of splitting `text` into two chunks, plus one character at a time.
    private func splits(of text: String) -> [[String]] {
        var result: [[String]] = [[text], text.map { String($0) }]
        for index in text.indices.dropFirst() {
            result.append([String(text[..<index]), String(text[index...])])
        }
        return result
    }

    @Test func plainAnswerWithoutTags() {
        let result = run(["Hello", " world"])
        #expect(result.parser.answerText == "Hello world")
        #expect(result.parser.thinkingText.isEmpty)
        #expect(result.parser.hasThinkingBlock == false)
        #expect(result.answer == "Hello world")
    }

    @Test func thinkBlockInOneChunk() {
        let result = run(["<think>\nLet me think.\n</think>\n\nThe answer is 4."])
        #expect(result.parser.thinkingText == "Let me think.")
        #expect(result.parser.answerText == "The answer is 4.")
        #expect(result.parser.isThinkingClosed)
        #expect(result.parser.isThinkingUnterminated == false)
    }

    @Test(arguments: [
        "<think>\nStep one.\nStep two.\n</think>\n\nDone <b>bold</b>.",
        "  \n<think>x</think>y",
        "<think></think>answer",
        "<think>\n\n</think>\n\nOnly answer",
        "No tags at all, just < and > and </ signs.",
        "<thinking is not a tag",
    ])
    func everySplitGivesSameResult(text: String) {
        let reference = run([text])
        for chunks in splits(of: text) {
            let result = run(chunks)
            #expect(result.parser.thinkingText == reference.parser.thinkingText, "\(chunks)")
            #expect(result.parser.answerText == reference.parser.answerText, "\(chunks)")
            // Deltas always add up to the accumulated values.
            #expect(result.thinking == result.parser.thinkingText, "\(chunks)")
            #expect(result.answer == result.parser.answerText, "\(chunks)")
        }
    }

    @Test func splitTagsAcrossChunks() {
        let result = run(["<th", "ink>", "rea", "son</th", "ink", ">\n\nAns", "wer"])
        #expect(result.parser.thinkingText == "reason")
        #expect(result.parser.answerText == "Answer")
    }

    @Test func emptyThinkBlockLeavesNoThinkingText() {
        let result = run(["<think>\n\n</think>\n\nHi there"])
        #expect(result.parser.thinkingText.isEmpty)
        #expect(result.parser.answerText == "Hi there")
        #expect(result.parser.hasThinkingBlock)
    }

    @Test func unterminatedThinkingIsFlushedOnFinish() {
        var parser = ThinkingParser()
        _ = parser.feed("<think>\nStill thinking about it")
        #expect(parser.phase == .thinking)
        let flushed = parser.finish()
        #expect(parser.thinkingText == "Still thinking about it")
        #expect(parser.answerText.isEmpty)
        #expect(parser.isThinkingUnterminated)
        #expect(flushed.isEmpty == false || parser.thinkingText == "Still thinking about it")
    }

    @Test func partialCloseTagIsHeldBackUntilResolved() {
        var parser = ThinkingParser()
        let first = parser.feed("<think>abc</thi")
        #expect(first == [.thinking("abc")])
        let second = parser.feed("s is not a tag")
        #expect(second == [.thinking("</this is not a tag")])
        _ = parser.finish()
        #expect(parser.thinkingText == "abc</this is not a tag")
        #expect(parser.isThinkingUnterminated)
    }

    @Test func partialOpenTagAtEndIsAnswerOnFinish() {
        let result = run(["<thi"])
        #expect(result.parser.answerText == "<thi")
        #expect(result.parser.thinkingText.isEmpty)
    }

    @Test func thinkTagLaterInAnswerIsText() {
        let text = "Use <think> tags like <think>this</think>."
        for chunks in splits(of: text) {
            let result = run(chunks)
            #expect(result.parser.answerText == text, "\(chunks)")
            #expect(result.parser.thinkingText.isEmpty, "\(chunks)")
            #expect(result.parser.hasThinkingBlock == false)
        }
    }

    @Test func bareCloseTagReclassifiesEarlierTextAsThinking() {
        var parser = ThinkingParser()
        var segments = parser.feed("Okay, the user asks")
        segments += parser.feed(" something.\n</think>\n\nFinal answer.")
        segments += parser.finish()
        #expect(parser.thinkingText == "Okay, the user asks something.")
        #expect(parser.answerText == "Final answer.")
        #expect(segments.contains(.answerMovedToThinking("Okay, the user asks something.")))
    }

    @Test func startsInsideThinking() {
        let result = run(["reasoning", "</think>", "answer"], startsInsideThinking: true)
        #expect(result.parser.thinkingText == "reasoning")
        #expect(result.parser.answerText == "answer")
    }

    @Test func whitespaceBeforeCloseTagIsDroppedButKeptInside() {
        let result = run(["<think>a", "\n", "b", "\n\n", "</think>c"])
        #expect(result.parser.thinkingText == "a\nb")
        #expect(result.parser.answerText == "c")
    }

    @Test func feedAfterFinishIsIgnored() {
        var parser = ThinkingParser()
        _ = parser.feed("x")
        _ = parser.finish()
        #expect(parser.feed("y").isEmpty)
        #expect(parser.answerText == "x")
    }

    @Test func splitConvenience() {
        let (thinking, answer) = ThinkingParser.split("<think>t</think>a")
        #expect(thinking == "t")
        #expect(answer == "a")
    }
}

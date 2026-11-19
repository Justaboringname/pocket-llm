import Foundation

/// One block of a Markdown document as this app renders it.
struct MarkdownBlock: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `marker` is `nil` for bullets, otherwise the ordinal as written (e.g. "3.").
        case listItem(marker: String?, depth: Int, text: String)
        case quote(String)
        /// `isClosed` is `false` while a streamed fence has not been closed yet.
        case code(language: String, code: String, isClosed: Bool)
        case table(header: [String], rows: [[String]])
        case rule
    }

    var kind: Kind
}

/// A small, forgiving block-level Markdown parser for model output.
///
/// It is line based and never fails: any prefix of a document (as seen while a reply streams)
/// parses into sensible blocks — an unclosed code fence becomes an in-progress code block, a
/// half-written list marker is plain text until the space after it arrives. Inline syntax
/// (bold, italic, code spans, links) is left in the block text and rendered later by
/// ``InlineMarkdown``.
enum MarkdownParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var paragraph: [Substring] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
            blocks.append(MarkdownBlock(kind: .paragraph(joined)))
            paragraph.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let indent = leadingSpaces(line)
            let content = line.dropFirst(min(indent, line.count))

            if content.allSatisfy(\.isWhitespace) {
                flushParagraph()
                index += 1
                continue
            }

            // Fenced code block.
            if indent <= 3, let fence = fenceOpening(content) {
                flushParagraph()
                var code: [Substring] = []
                var closed = false
                index += 1
                while index < lines.count {
                    let codeLine = lines[index]
                    if isFenceClosing(codeLine, fence: fence) {
                        closed = true
                        index += 1
                        break
                    }
                    code.append(dropIndent(codeLine, upTo: indent))
                    index += 1
                }
                blocks.append(
                    MarkdownBlock(
                        kind: .code(
                            language: fence.info, code: code.joined(separator: "\n"),
                            isClosed: closed)))
                continue
            }

            if indent <= 3, let heading = heading(content) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level, text: heading.text)))
                index += 1
                continue
            }

            if indent <= 3, isRule(content) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .rule))
                index += 1
                continue
            }

            if indent <= 3, content.first == ">" {
                flushParagraph()
                var quoted: [Substring] = []
                while index < lines.count {
                    let quoteLine = lines[index]
                    let stripped = quoteLine.drop(while: { $0 == " " })
                    guard stripped.first == ">" else { break }
                    var rest = stripped.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(rest)
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .quote(quoted.joined(separator: "\n"))))
                continue
            }

            if content.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = tableCells(content)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let rowLine = lines[index]
                    guard rowLine.contains("|"), !rowLine.allSatisfy(\.isWhitespace) else { break }
                    rows.append(tableCells(rowLine))
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .table(header: header, rows: rows)))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                var itemLines: [Substring] = [item.text]
                index += 1
                // Continuation lines: non-blank lines that do not start another block.
                while index < lines.count {
                    let next = lines[index]
                    if next.allSatisfy(\.isWhitespace) || startsBlock(next) { break }
                    itemLines.append(next.drop(while: { $0 == " " }))
                    index += 1
                }
                blocks.append(
                    MarkdownBlock(
                        kind: .listItem(
                            marker: item.marker, depth: item.depth,
                            text: itemLines.joined(separator: "\n"))))
                continue
            }

            paragraph.append(content)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Line classification

    private struct Fence {
        let character: Character
        let length: Int
        let info: String
    }

    private static func leadingSpaces(_ line: Substring) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }
        return count
    }

    private static func dropIndent(_ line: Substring, upTo count: Int) -> Substring {
        var remaining = count
        var result = line
        while remaining > 0, result.first == " " {
            result = result.dropFirst()
            remaining -= 1
        }
        return result
    }

    private static func fenceOpening(_ content: Substring) -> Fence? {
        guard let first = content.first, first == "`" || first == "~" else { return nil }
        let run = content.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        let info = content.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init) ?? ""
        return Fence(character: first, length: run, info: language)
    }

    private static func isFenceClosing(_ line: Substring, fence: Fence) -> Bool {
        let content = line.drop(while: { $0 == " " })
        guard leadingSpaces(line) <= 3 else { return false }
        let run = content.prefix(while: { $0 == fence.character }).count
        guard run >= fence.length else { return false }
        return content.dropFirst(run).allSatisfy(\.isWhitespace)
    }

    private static func heading(_ content: Substring) -> (level: Int, text: String)? {
        let hashes = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = content.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes ("## Title ##").
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ content: Substring) -> Bool {
        let characters = content.filter { $0 != " " }
        guard characters.count >= 3, let first = characters.first,
            first == "-" || first == "*" || first == "_"
        else { return false }
        return characters.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") else {
            return false
        }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func tableCells(_ line: Substring) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: Substring) -> (marker: String?, depth: Int, text: Substring)? {
        let indent = leadingSpaces(line)
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = content.first else { return nil }
        let depth = min(indent / 2, 4)
        if first == "-" || first == "*" || first == "+" {
            let rest = content.dropFirst()
            guard rest.first == " " else { return nil }
            return (nil, depth, rest.drop(while: { $0 == " " }))
        }
        let digits = content.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...9).contains(digits.count) else { return nil }
        let afterDigits = content.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
            return nil
        }
        let rest = afterDigits.dropFirst()
        guard rest.first == " " else { return nil }
        return ("\(digits)\(delimiter)", min(indent / 3, 4), rest.drop(while: { $0 == " " }))
    }

    /// Whether `line` would start a new block (used to end paragraphs and list items).
    private static func startsBlock(_ line: Substring) -> Bool {
        let indent = leadingSpaces(line)
        let content = line.dropFirst(min(indent, line.count))
        if listItem(line) != nil { return true }
        guard indent <= 3 else { return false }
        return fenceOpening(content) != nil || heading(content) != nil || isRule(content)
            || content.first == ">"
    }
}

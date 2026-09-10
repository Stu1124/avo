import Foundation

// MARK: - Block model

/// One block-level element of a markdown document, as produced by `MdParser`.
enum MdBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case code(language: String?, code: String)
    case list(ordered: Bool, items: [String])
    case blockquote(text: String)
    case mathBlock(latex: String)
    case thematicBreak
}

// MARK: - Parser

/// Line-oriented block parser for Avo's response bubbles.
///
/// It runs on the main actor for every streamed chunk of a reply, so two properties matter as much
/// as the output: every branch of the loop must consume at least one line, and no branch may be
/// worse than linear in the input. Both are covered by `tests/MdParserTests.swift`.
///
/// Line classification is hand-written rather than regex-based. A `#` that is not followed by a
/// space is not a heading — `#hashtag`, `#378FFF` and a bare `#` at the end of a half-streamed
/// buffer are all ordinary paragraph text, and they must not stall the paragraph collector.
enum MdParser {
    static func parse(_ source: String) -> [MdBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MdBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line — skip
            if trimmed.isEmpty { i += 1; continue }

            // Display math block: $$ ... $$
            if trimmed.hasPrefix("$$") {
                let (block, next) = parseMathBlock(lines: lines, from: i)
                if let block { blocks.append(block) }
                i = max(next, i + 1); continue
            }

            // Fenced code block: ``` or ~~~
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { i += 1; break }
                    codeLines.append(lines[i])
                    i += 1
                }
                // Trim trailing empty lines in code block
                while codeLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { codeLines.removeLast() }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // Heading: # through ###### followed by a space
            if let heading = heading(trimmed) {
                blocks.append(.heading(level: min(heading.level, 4), text: heading.text))
                i += 1; continue
            }

            // Thematic break: ---, ***, ___
            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                i += 1; continue
            }

            // Unordered list: - or * or + prefix
            if bulletContent(trimmed) != nil {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.isEmpty { break }
                    if let content = bulletContent(l) {
                        items.append(content)
                    } else if !items.isEmpty {
                        // continuation line
                        items[items.count - 1] += " " + l
                    } else { break }
                    i += 1
                }
                blocks.append(.list(ordered: false, items: items))
                continue
            }

            // Ordered list: 1. 2. etc.
            if numberedContent(trimmed) != nil {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.isEmpty { break }
                    if let content = numberedContent(l) {
                        items.append(content)
                    } else if !items.isEmpty {
                        items[items.count - 1] += " " + l
                    } else { break }
                    i += 1
                }
                blocks.append(.list(ordered: true, items: items))
                continue
            }

            // Blockquote: > prefix
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if !l.hasPrefix(">") { break }
                    quoteLines.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: " ")))
                continue
            }

            // Paragraph: collect contiguous non-empty, non-special lines. A `#` line only ends the
            // paragraph when it is a real heading; anything else starting with `#` is body text.
            var paraLines: [String] = []
            while i < lines.count {
                let lt = lines[i].trimmingCharacters(in: .whitespaces)
                if lt.isEmpty { break }
                if lt.hasPrefix("```") || lt.hasPrefix("~~~") || lt.hasPrefix("$$") { break }
                if heading(lt) != nil { break }
                if bulletContent(lt) != nil { break }
                if numberedContent(lt) != nil { break }
                if lt.hasPrefix(">") { break }
                paraLines.append(lt)
                i += 1
            }
            if paraLines.isEmpty {
                // Nothing was consumed: the line is special to the paragraph collector but was not
                // claimed by any branch above. Emit it verbatim rather than spinning forever.
                blocks.append(.paragraph(text: trimmed))
                i += 1
            } else {
                blocks.append(.paragraph(text: paraLines.joined(separator: " ")))
            }
        }
        return blocks
    }

    // MARK: - Line classification

    /// `#` … `######` followed by whitespace and at least one more character.
    static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == "#" {
            level += 1
            if level > 6 { return nil }
            idx = trimmed.index(after: idx)
        }
        guard level > 0, idx < trimmed.endIndex, trimmed[idx].isWhitespace else { return nil }
        let text = trimmed[idx...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    /// `-`, `*` or `+` followed by whitespace. The item text may be empty.
    private static func bulletContent(_ trimmed: String) -> String? {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "+" else { return nil }
        let afterMarker = trimmed.index(after: trimmed.startIndex)
        guard afterMarker < trimmed.endIndex, trimmed[afterMarker].isWhitespace else { return nil }
        return String(trimmed[afterMarker...]).trimmingCharacters(in: .whitespaces)
    }

    /// One or more digits, a `.`, then whitespace. The item text may be empty.
    private static func numberedContent(_ trimmed: String) -> String? {
        var idx = trimmed.startIndex
        var digits = 0
        while idx < trimmed.endIndex, trimmed[idx].isASCII, trimmed[idx].isNumber {
            digits += 1
            idx = trimmed.index(after: idx)
        }
        guard digits > 0, idx < trimmed.endIndex, trimmed[idx] == "." else { return nil }
        idx = trimmed.index(after: idx)
        guard idx < trimmed.endIndex, trimmed[idx].isWhitespace else { return nil }
        return String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for marker: Character in ["-", "*", "_"] {
            var count = 0
            var onlyMarker = true
            for ch in trimmed {
                if ch == marker { count += 1 } else if ch != " " { onlyMarker = false; break }
            }
            if onlyMarker && count >= 3 { return true }
        }
        return false
    }

    // MARK: - Math

    private static func parseMathBlock(lines: [String], from start: Int) -> (MdBlock?, Int) {
        let firstLine = lines[start].trimmingCharacters(in: .whitespaces)
        // Single-line: $$ expression $$
        if firstLine.hasPrefix("$$") && firstLine.dropFirst(2).contains("$$") {
            let inner = String(firstLine.dropFirst(2))
            if let end = inner.range(of: "$$") {
                let latex = String(inner[inner.startIndex..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                return (.mathBlock(latex: latex), start + 1)
            }
        }
        // Multi-line: $$ ... $$
        var mathLines: [String] = []
        var i = start + 1
        let opening = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if !opening.isEmpty { mathLines.append(opening) }
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l.hasSuffix("$$") || l == "$$" {
                let before = l.replacingOccurrences(of: "$$", with: "").trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { mathLines.append(before) }
                return (.mathBlock(latex: mathLines.joined(separator: " ")), i + 1)
            }
            mathLines.append(l)
            i += 1
        }
        // No closing $$, treat as paragraph
        return (.paragraph(text: firstLine), start + 1)
    }
}

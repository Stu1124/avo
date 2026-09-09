import SwiftUI

/// Block-level markdown renderer for Avo's response bubbles.
/// Handles headings, fenced code blocks, bullet/numbered lists, blockquotes,
/// display/inline LaTeX math, and regular paragraphs with inline formatting.
struct MarkdownView: View {
    let source: String
    var baseFontSize: CGFloat = 15

    private var blocks: [MdBlock] { MdParser.parse(MathSyntax.normalize(source)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder private func blockView(_ block: MdBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? baseFontSize + 5 : level == 2 ? baseFontSize + 3 : baseFontSize + 1
            let weight: Font.Weight = level <= 2 ? .bold : .semibold
            InlineMarkdownText(source: text, size: size, weight: weight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 1 ? 4 : 2)

        case .paragraph(let text):
            InlineMarkdownText(source: text, size: baseFontSize)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 4)
                }
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, language != nil ? 4 : 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(i + 1)." : "\u{2022}")
                            .font(Theme.text(baseFontSize, ordered ? .medium : .regular))
                            .foregroundStyle(Theme.ink3)
                            .frame(width: ordered ? 20 : 10, alignment: ordered ? .trailing : .center)
                        InlineMarkdownText(source: item, size: baseFontSize)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent.opacity(0.5))
                    .frame(width: 3)
                InlineMarkdownText(source: text, size: baseFontSize, color: Theme.ink2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
            }

        case .mathBlock(let latex):
            MathBlockView(latex: latex, size: baseFontSize + 2)

        case .thematicBreak:
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 2)
        }
    }

}

// MARK: - Block model

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
                i = next; continue
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

            // Heading: # through ######
            if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                let level = match.1.count
                let text = String(match.2)
                blocks.append(.heading(level: min(level, 4), text: text))
                i += 1; continue
            }

            // Thematic break: ---, ***, ___
            if trimmed.count >= 3 && (trimmed.allSatisfy({ $0 == "-" || $0 == " " }) && trimmed.filter({ $0 == "-" }).count >= 3
                || trimmed.allSatisfy({ $0 == "*" || $0 == " " }) && trimmed.filter({ $0 == "*" }).count >= 3
                || trimmed.allSatisfy({ $0 == "_" || $0 == " " }) && trimmed.filter({ $0 == "_" }).count >= 3) {
                blocks.append(.thematicBreak)
                i += 1; continue
            }

            // Unordered list: - or * or + prefix
            if trimmed.firstMatch(of: /^[-*+]\s+/) != nil {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.isEmpty { break }
                    if let m = l.firstMatch(of: /^[-*+]\s+(.*)$/) {
                        items.append(String(m.1))
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
            if trimmed.firstMatch(of: /^\d+\.\s+/) != nil {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.isEmpty { break }
                    if let m = l.firstMatch(of: /^\d+\.\s+(.*)$/) {
                        items.append(String(m.1))
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
                    if l.hasPrefix(">") {
                        let content = String(l.dropFirst()).trimmingCharacters(in: .whitespaces)
                        quoteLines.append(content)
                    } else if l.isEmpty || !l.hasPrefix(">") { break }
                    i += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: " ")))
                continue
            }

            // Paragraph: collect contiguous non-empty, non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                let lt = l.trimmingCharacters(in: .whitespaces)
                if lt.isEmpty { break }
                if lt.hasPrefix("```") || lt.hasPrefix("~~~") || lt.hasPrefix("#") || lt.hasPrefix("$$") { break }
                if lt.firstMatch(of: /^[-*+]\s+/) != nil { break }
                if lt.firstMatch(of: /^\d+\.\s+/) != nil { break }
                if lt.hasPrefix(">") { break }
                paraLines.append(lt)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(text: paraLines.joined(separator: " ")))
            }
        }
        return blocks
    }

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

// MARK: - LaTeX → Unicode math renderer

enum MathRenderer {
    /// Render a display-math LaTeX string into readable Unicode text.
    static func render(_ latex: String) -> String {
        var s = latex
        s = expandCommands(s)
        s = expandFractions(s)
        s = expandSuperscripts(s)
        s = expandSubscripts(s)
        s = cleanBraces(s)
        s = s.replacingOccurrences(of: "\\\\", with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Process inline math: replace $...$ (but not $$) with rendered Unicode.
    static func processInlineMath(_ text: String) -> String {
        guard text.contains("$") else { return text }
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "$" {
                let next = text.index(after: i)
                // Skip $$ (display math markers shouldn't appear in inline text)
                if next < text.endIndex && text[next] == "$" {
                    result.append("$")
                    i = next; continue
                }
                // Find closing $
                if let closeIdx = text[next...].firstIndex(of: "$") {
                    let latex = String(text[next..<closeIdx])
                    // Only render if it looks like math (not empty, not just a number)
                    if !latex.trimmingCharacters(in: .whitespaces).isEmpty {
                        result.append(render(latex))
                    }
                    i = text.index(after: closeIdx)
                    continue
                }
            }
            result.append(text[i])
            i = text.index(after: i)
        }
        return result
    }

    private static let commands: [(String, String)] = [
        // Greek lowercase
        ("\\alpha", "\u{03B1}"), ("\\beta", "\u{03B2}"), ("\\gamma", "\u{03B3}"), ("\\delta", "\u{03B4}"),
        ("\\epsilon", "\u{03B5}"), ("\\varepsilon", "\u{03B5}"), ("\\zeta", "\u{03B6}"), ("\\eta", "\u{03B7}"),
        ("\\theta", "\u{03B8}"), ("\\vartheta", "\u{03D1}"), ("\\iota", "\u{03B9}"), ("\\kappa", "\u{03BA}"),
        ("\\lambda", "\u{03BB}"), ("\\mu", "\u{03BC}"), ("\\nu", "\u{03BD}"), ("\\xi", "\u{03BE}"),
        ("\\pi", "\u{03C0}"), ("\\rho", "\u{03C1}"), ("\\sigma", "\u{03C3}"), ("\\tau", "\u{03C4}"),
        ("\\upsilon", "\u{03C5}"), ("\\phi", "\u{03C6}"), ("\\varphi", "\u{03D5}"), ("\\chi", "\u{03C7}"),
        ("\\psi", "\u{03C8}"), ("\\omega", "\u{03C9}"),
        // Greek uppercase
        ("\\Gamma", "\u{0393}"), ("\\Delta", "\u{0394}"), ("\\Theta", "\u{0398}"), ("\\Lambda", "\u{039B}"),
        ("\\Xi", "\u{039E}"), ("\\Pi", "\u{03A0}"), ("\\Sigma", "\u{03A3}"), ("\\Upsilon", "\u{03A5}"),
        ("\\Phi", "\u{03A6}"), ("\\Psi", "\u{03A8}"), ("\\Omega", "\u{03A9}"),
        // Operators and symbols
        ("\\sum", "\u{2211}"), ("\\prod", "\u{220F}"), ("\\int", "\u{222B}"), ("\\iint", "\u{222C}"),
        ("\\iiint", "\u{222D}"), ("\\oint", "\u{222E}"),
        ("\\infty", "\u{221E}"), ("\\infinity", "\u{221E}"),
        ("\\sqrt", "\u{221A}"), ("\\partial", "\u{2202}"), ("\\nabla", "\u{2207}"),
        ("\\pm", "\u{00B1}"), ("\\mp", "\u{2213}"), ("\\times", "\u{00D7}"), ("\\div", "\u{00F7}"),
        ("\\cdot", "\u{00B7}"), ("\\circ", "\u{2218}"), ("\\bullet", "\u{2022}"),
        ("\\leq", "\u{2264}"), ("\\le", "\u{2264}"), ("\\geq", "\u{2265}"), ("\\ge", "\u{2265}"),
        ("\\neq", "\u{2260}"), ("\\ne", "\u{2260}"), ("\\approx", "\u{2248}"), ("\\equiv", "\u{2261}"),
        ("\\sim", "\u{223C}"), ("\\simeq", "\u{2243}"), ("\\propto", "\u{221D}"),
        ("\\in", "\u{2208}"), ("\\notin", "\u{2209}"), ("\\subset", "\u{2282}"), ("\\supset", "\u{2283}"),
        ("\\subseteq", "\u{2286}"), ("\\supseteq", "\u{2287}"),
        ("\\cup", "\u{222A}"), ("\\cap", "\u{2229}"), ("\\emptyset", "\u{2205}"), ("\\varnothing", "\u{2205}"),
        ("\\forall", "\u{2200}"), ("\\exists", "\u{2203}"), ("\\nexists", "\u{2204}"),
        ("\\neg", "\u{00AC}"), ("\\land", "\u{2227}"), ("\\lor", "\u{2228}"),
        ("\\to", "\u{2192}"), ("\\rightarrow", "\u{2192}"), ("\\leftarrow", "\u{2190}"),
        ("\\Rightarrow", "\u{21D2}"), ("\\Leftarrow", "\u{21D0}"), ("\\Leftrightarrow", "\u{21D4}"),
        ("\\mapsto", "\u{21A6}"),
        ("\\ldots", "\u{2026}"), ("\\cdots", "\u{22EF}"), ("\\dots", "\u{2026}"),
        ("\\langle", "\u{27E8}"), ("\\rangle", "\u{27E9}"),
        ("\\lceil", "\u{2308}"), ("\\rceil", "\u{2309}"), ("\\lfloor", "\u{230A}"), ("\\rfloor", "\u{230B}"),
        ("\\star", "\u{22C6}"),
        ("\\hbar", "\u{210F}"), ("\\ell", "\u{2113}"), ("\\Re", "\u{211C}"), ("\\Im", "\u{2111}"),
        // Spacing / formatting
        ("\\quad", "  "), ("\\qquad", "    "), ("\\,", " "), ("\\;", " "), ("\\:", " "),
        ("\\text", ""), ("\\mathrm", ""), ("\\mathbf", ""), ("\\mathit", ""), ("\\mathcal", ""),
        ("\\left", ""), ("\\right", ""), ("\\big", ""), ("\\Big", ""), ("\\bigg", ""), ("\\Bigg", ""),
        ("\\displaystyle", ""), ("\\textstyle", ""),
    ]

    private static func expandCommands(_ s: String) -> String {
        var r = s
        for (cmd, repl) in commands {
            r = r.replacingOccurrences(of: cmd, with: repl)
        }
        return r
    }

    /// \frac{a}{b} → a/b
    private static func expandFractions(_ s: String) -> String {
        var r = s
        // Handle \frac{...}{...}
        while let range = r.range(of: "\\frac") {
            let after = range.upperBound
            guard let (num, afterNum) = extractBraced(r, from: after),
                  let (den, afterDen) = extractBraced(r, from: afterNum) else {
                r.replaceSubrange(range, with: "frac")
                continue
            }
            let fraction = "(\(num))/(\(den))"
            r.replaceSubrange(range.lowerBound..<afterDen, with: fraction)
        }
        return r
    }

    private static let superscriptMap: [Character: Character] = [
        "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}",
        "4": "\u{2074}", "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}",
        "8": "\u{2078}", "9": "\u{2079}", "+": "\u{207A}", "-": "\u{207B}",
        "=": "\u{207C}", "(": "\u{207D}", ")": "\u{207E}", "n": "\u{207F}",
        "i": "\u{2071}",
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "\u{2080}", "1": "\u{2081}", "2": "\u{2082}", "3": "\u{2083}",
        "4": "\u{2084}", "5": "\u{2085}", "6": "\u{2086}", "7": "\u{2087}",
        "8": "\u{2088}", "9": "\u{2089}", "+": "\u{208A}", "-": "\u{208B}",
        "=": "\u{208C}", "(": "\u{208D}", ")": "\u{208E}",
        "a": "\u{2090}", "e": "\u{2091}", "o": "\u{2092}", "x": "\u{2093}",
        "i": "\u{1D62}", "j": "\u{2C7C}", "k": "\u{2096}", "n": "\u{2099}",
    ]

    private static func expandSuperscripts(_ s: String) -> String {
        var r = s
        // ^{...} or ^c (single char)
        while let caret = r.firstIndex(of: "^") {
            let after = r.index(after: caret)
            guard after < r.endIndex else { r.remove(at: caret); break }
            if r[after] == "{" {
                if let (content, end) = extractBraced(r, from: after) {
                    let sup = String(content.compactMap { superscriptMap[$0] ?? $0 })
                    r.replaceSubrange(caret..<end, with: sup)
                } else { r.remove(at: caret) }
            } else {
                let ch = r[after]
                let sup = superscriptMap[ch].map(String.init) ?? String(ch)
                let end = r.index(after: after)
                r.replaceSubrange(caret..<end, with: sup)
            }
        }
        return r
    }

    private static func expandSubscripts(_ s: String) -> String {
        var r = s
        while let under = r.firstIndex(of: "_") {
            let after = r.index(after: under)
            guard after < r.endIndex else { r.remove(at: under); break }
            if r[after] == "{" {
                if let (content, end) = extractBraced(r, from: after) {
                    let sub = String(content.compactMap { subscriptMap[$0] ?? $0 })
                    r.replaceSubrange(under..<end, with: sub)
                } else { r.remove(at: under) }
            } else {
                let ch = r[after]
                let sub = subscriptMap[ch].map(String.init) ?? String(ch)
                let end = r.index(after: after)
                r.replaceSubrange(under..<end, with: sub)
            }
        }
        return r
    }

    /// Extract content between matched braces: { ... }
    private static func extractBraced(_ s: String, from start: String.Index) -> (String, String.Index)? {
        guard start < s.endIndex, s[start] == "{" else { return nil }
        var depth = 0
        var i = start
        while i < s.endIndex {
            if s[i] == "{" { depth += 1 }
            else if s[i] == "}" { depth -= 1; if depth == 0 {
                let content = String(s[s.index(after: start)..<i])
                return (content, s.index(after: i))
            }}
            i = s.index(after: i)
        }
        return nil
    }

    /// Remove leftover braces that were just grouping.
    private static func cleanBraces(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }
}

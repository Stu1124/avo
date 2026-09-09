import SwiftUI
import AppKit
import SwiftMath

/// Typesets LaTeX with SwiftMath (CoreText, Latin Modern) into cached images with baseline metrics,
/// so formulas can sit inline inside SwiftUI `Text` runs or stand alone as display blocks.
enum MathTypesetter {
    struct Rendered {
        let image: NSImage
        let ascent: CGFloat
        let descent: CGFloat
        var size: CGSize { image.size }
    }

    private final class Box { let r: Rendered; init(_ r: Rendered) { self.r = r } }
    private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 400; return c }()

    /// Returns nil when SwiftMath cannot parse the expression; callers fall back to Unicode text.
    @MainActor
    static func render(_ latex: String, fontSize: CGFloat, display: Bool, color: NSColor) -> Rendered? {
        let key = "\(display ? "D" : "T")|\(fontSize)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.r }
        let label = MTMathUILabel()
        label.fontSize = fontSize
        label.textColor = color
        label.labelMode = display ? .display : .text
        label.displayErrorInline = false
        label.latex = latex
        guard label.error == nil, label.mathList != nil else { return nil }
        let fit = label.fittingSize
        guard fit.width > 0, fit.height > 0 else { return nil }
        let pad: CGFloat = 1
        let size = CGSize(width: ceil(fit.width) + 2 * pad, height: ceil(fit.height) + 2 * pad)
        label.contentInsets = MTEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        label.frame = CGRect(origin: .zero, size: size)
        label.layout()
        guard let dl = label.displayList else { return nil }
        let descent = dl.descent + pad
        let ascent = size.height - descent
        let image = NSImage(size: size, flipped: false) { _ in
            label.draw(label.bounds)
            return true
        }
        let r = Rendered(image: image, ascent: ascent, descent: descent)
        cache.setObject(Box(r), forKey: key)
        return r
    }
}

// MARK: - Source normalisation

enum MathSyntax {
    private static let displayBracket = try! NSRegularExpression(pattern: #"\\\[(.*?)\\\]"#, options: [.dotMatchesLineSeparators])
    private static let inlineParen = try! NSRegularExpression(pattern: #"\\\((.*?)\\\)"#, options: [.dotMatchesLineSeparators])
    private static let inlineDouble = try! NSRegularExpression(pattern: #"(?<=\S)\s*\$\$(.+?)\$\$"#, options: [])

    /// Rewrites `\[...\]` → `$$...$$` on its own lines and `\(...\)` → `$...$`, and lifts `$$...$$` that appears
    /// mid-line onto its own lines, so the block parser only has to know about `$` delimiters.
    static func normalize(_ source: String) -> String {
        guard source.contains("\\") || source.contains("$$") else { return source }
        var s = source
        s = displayBracket.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n\\$\\$$1\\$\\$\n")
        s = inlineParen.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\\$$1\\$")
        s = inlineDouble.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n\\$\\$$1\\$\\$\n")
        return s
    }

    /// Strips commands SwiftMath does not know and reports whether the whole expression was `\boxed{}`.
    static func sanitize(_ latex: String) -> (latex: String, boxed: Bool) {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        var boxed = false
        if s.hasPrefix("\\boxed{"), let inner = braced(s, at: s.index(s.startIndex, offsetBy: 6)), inner.end == s.endIndex {
            s = inner.content; boxed = true
        }
        while let r = s.range(of: "\\boxed") {
            if let inner = braced(s, at: r.upperBound) { s.replaceSubrange(r.lowerBound..<inner.end, with: "{\(inner.content)}") }
            else { s.removeSubrange(r) }
        }
        while let r = s.range(of: "\\tag") {
            let star = s[r.upperBound...].hasPrefix("*") ? s.index(after: r.upperBound) : r.upperBound
            if let inner = braced(s, at: star) { s.removeSubrange(r.lowerBound..<inner.end) } else { s.removeSubrange(r) }
        }
        for cmd in ["\\hspace", "\\phantom", "\\label"] {
            while let r = s.range(of: cmd) {
                if let inner = braced(s, at: r.upperBound) { s.removeSubrange(r.lowerBound..<inner.end) } else { s.removeSubrange(r) }
            }
        }
        for (cmd, repl) in [("\\displaystyle", ""), ("\\textstyle", ""), ("\\dots", "\\ldots"),
                            ("\\therefore", "\\text{ ∴ }"), ("\\because", "\\text{ ∵ }")] {
            s = s.replacingOccurrences(of: cmd, with: repl)
        }
        return (s, boxed)
    }

    private static func braced(_ s: String, at start: String.Index) -> (content: String, end: String.Index)? {
        guard start < s.endIndex, s[start] == "{" else { return nil }
        var depth = 0
        var i = start
        while i < s.endIndex {
            if s[i] == "{" { depth += 1 }
            else if s[i] == "}" {
                depth -= 1
                if depth == 0 { return (String(s[s.index(after: start)..<i]), s.index(after: i)) }
            }
            i = s.index(after: i)
        }
        return nil
    }

    enum Segment { case text(String), math(String) }

    /// Splits a paragraph into text and `$...$` math runs. Pandoc rule: the opening `$` must be followed by
    /// a non-space and the closing `$` preceded by one, so "$5 and $10" stays prose.
    static func segments(_ text: String) -> [Segment] {
        guard text.contains("$") else { return [.text(text)] }
        var out: [Segment] = []
        var buf = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "$" {
                buf.append("$"); i = text.index(i, offsetBy: 2); continue
            }
            if c == "$" {
                let open = text.index(after: i)
                if open < text.endIndex, !text[open].isWhitespace, text[open] != "$" {
                    var j = open
                    var found: String.Index? = nil
                    while j < text.endIndex {
                        if text[j] == "$", !text[text.index(before: j)].isWhitespace, text[text.index(before: j)] != "\\" { found = j; break }
                        j = text.index(after: j)
                    }
                    if let close = found {
                        if !buf.isEmpty { out.append(.text(buf)); buf = "" }
                        out.append(.math(String(text[open..<close])))
                        i = text.index(after: close); continue
                    }
                }
            }
            buf.append(c)
            i = text.index(after: i)
        }
        if !buf.isEmpty { out.append(.text(buf)) }
        return out
    }
}

// MARK: - Views

/// A paragraph of inline markdown with `$...$` math typeset and baseline-aligned inside the text run.
struct InlineMarkdownText: View {
    let source: String
    var size: CGFloat = 15
    var weight: Font.Weight = .regular
    var color: Color = Theme.ink

    var body: some View {
        composed
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
    }

    private var composed: Text {
        let segments = MathSyntax.segments(source)
        var t = Text("")
        for seg in segments {
            switch seg {
            case .text(let s):
                t = t + Text(Self.attributed(s))
            case .math(let latex):
                let (clean, _) = MathSyntax.sanitize(latex)
                if let r = MathTypesetter.render(clean, fontSize: size, display: false, color: NSColor(color)) {
                    t = t + Text(Image(nsImage: r.image)).baselineOffset(-r.descent)
                } else {
                    t = t + Text(MathRenderer.render(latex)).font(.system(size: size, design: .serif))
                }
            }
        }
        return t
    }

    private static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Centered display math. Expressions wider than the panel scale down to fit; `\boxed{}` draws a ring.
struct MathBlockView: View {
    let latex: String
    var size: CGFloat = 17
    var color: Color = Theme.ink
    var maxWidth: CGFloat = 340

    var body: some View {
        let (clean, boxed) = MathSyntax.sanitize(latex)
        Group {
            if let r = MathTypesetter.render(clean, fontSize: size, display: true, color: NSColor(color)) {
                Image(nsImage: r.image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: min(r.size.width, maxWidth))
                    .padding(.horizontal, boxed ? 12 : 0).padding(.vertical, boxed ? 6 : 0)
                    .overlay {
                        if boxed {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.2)
                        }
                    }
            } else {
                Text(MathRenderer.render(latex))
                    .font(.system(size: size, design: .serif))
                    .foregroundStyle(color)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.6))
    }
}

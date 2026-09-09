import Foundation

/// Pure text work behind the web tools: reading DuckDuckGo's HTML results page, and turning an
/// arbitrary page into plain text. Nothing here touches the network, so it can be tested against a
/// saved fixture (see tests/WebToolsTests.swift).
enum DDGParser {
    struct Result: Equatable {
        var title: String
        var url: String
        var snippet: String
    }

    // MARK: - Results page

    /// Pulls up to `limit` results out of the HTML DuckDuckGo serves at html.duckduckgo.com.
    ///
    /// The page is a flat run of blocks; each one carries the link as `class="result__a"` and the
    /// summary as `class="result__snippet"`. Rather than parse the document, walk the anchors in
    /// order and take the snippet that falls between one anchor and the next. Sponsored rows use the
    /// same class but point at DuckDuckGo's own redirector, and `resolve` drops those.
    static func results(from html: String, limit: Int) -> [Result] {
        guard limit > 0 else { return [] }
        var out: [Result] = []
        var cursor = html.startIndex
        while out.count < limit, let marker = html.range(of: "result__a", range: cursor..<html.endIndex) {
            guard let tagStart = html.range(of: "<a", options: .backwards, range: html.startIndex..<marker.lowerBound),
                  let tagEnd = html.range(of: ">", range: marker.upperBound..<html.endIndex) else {
                cursor = marker.upperBound
                continue
            }
            let href = attribute("href", in: String(html[tagStart.lowerBound..<tagEnd.upperBound])) ?? ""
            let (title, afterTitle) = inner(html, from: tagEnd.upperBound)
            cursor = afterTitle
            let url = resolve(href)
            guard !url.isEmpty, !title.isEmpty else { continue }
            let nextAnchor = html.range(of: "result__a", range: cursor..<html.endIndex)?.lowerBound ?? html.endIndex
            var snippet = ""
            if let sn = html.range(of: "result__snippet", range: cursor..<nextAnchor),
               let snEnd = html.range(of: ">", range: sn.upperBound..<html.endIndex) {
                snippet = inner(html, from: snEnd.upperBound).0
            }
            out.append(Result(title: title, url: url, snippet: snippet))
        }
        return out
    }

    /// The real destination behind a result link. DuckDuckGo wraps every one in `/l/?uddg=<escaped>`;
    /// an ad row instead points at `y.js`, which is not a result and comes back empty.
    static func resolve(_ href: String) -> String {
        var h = decodeEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "uddg=") {
            let value = h[r.upperBound...].prefix { $0 != "&" }
            if let decoded = String(value).removingPercentEncoding, !decoded.isEmpty { h = decoded }
        }
        if h.hasPrefix("//") { h = "https:" + h }
        guard h.hasPrefix("http://") || h.hasPrefix("https://") else { return "" }
        if h.contains("duckduckgo.com/y.js") || h.contains("duckduckgo.com/l/") { return "" }
        return h
    }

    // MARK: - Whole page

    /// A page as readable text: scripts, styles and markup gone, block ends kept as line breaks,
    /// runs of whitespace collapsed, cut to `limit` characters.
    static func readableText(fromHTML html: String, limit: Int) -> String {
        // `title` goes with the rest: it is read separately, and left in it becomes a stray first
        // line of body text on every page.
        var s = removeElements(html, tags: ["script", "style", "noscript", "svg", "template", "title"])
        s = removeComments(s)
        for tag in ["</p", "</div", "</li", "</tr", "</h1", "</h2", "</h3", "</h4", "</h5", "</h6",
                    "</section", "</article", "</header", "</footer", "</blockquote", "<br"] {
            s = s.replacingOccurrences(of: tag, with: "\n" + tag, options: .caseInsensitive)
        }
        s = decodeEntities(stripTags(s))
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { collapse(String($0)) }
            .filter { !$0.isEmpty }
        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    /// The `<title>` of a page, cleaned up. Empty when there is none.
    static func title(fromHTML html: String) -> String {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: openEnd.upperBound..<html.endIndex)
        else { return "" }
        return collapse(decodeEntities(stripTags(String(html[openEnd.upperBound..<close.lowerBound]))))
    }

    // MARK: - Text helpers

    /// Everything from `i` up to whichever closing tag comes first, cleaned, plus where it ended.
    /// A result title closes with `</a>`; a snippet is an `<a>` on some pages and a `<div>` on others.
    private static func inner(_ html: String, from i: String.Index) -> (String, String.Index) {
        let ends = ["</a>", "</div>", "</td>"].compactMap {
            html.range(of: $0, options: .caseInsensitive, range: i..<html.endIndex)?.lowerBound
        }
        let end = ends.min() ?? html.endIndex
        return (collapse(decodeEntities(stripTags(String(html[i..<end])))), end)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        for quote in ["\"", "'"] {
            guard let r = tag.range(of: name + "=" + quote) else { continue }
            let rest = tag[r.upperBound...]
            guard let end = rest.firstIndex(of: Character(quote)) else { continue }
            return String(rest[..<end])
        }
        return nil
    }

    static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true }
            else if ch == ">" { inTag = false }
            else if !inTag { out.append(ch) }
        }
        return out
    }

    /// Every run of whitespace becomes one space, and the ends are trimmed.
    static func collapse(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s {
            if ch.isWhitespace { pendingSpace = !out.isEmpty; continue }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(ch)
        }
        return out
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "\u{2019}", "lsquo": "\u{2018}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "middot": "·", "trade": "™", "copy": "©", "reg": "®",
    ]

    /// Named and numeric HTML entities. Anything unrecognised is left exactly as it was written.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            guard ch == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 12 else {
                out.append(ch)
                i = s.index(after: i)
                continue
            }
            let body = String(s[s.index(after: i)..<semi])
            if let replacement = named[body.lowercased()] {
                out += replacement
            } else if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let hex = digits.first == "x" || digits.first == "X"
                let value = hex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                if let v = value, let scalar = Unicode.Scalar(v) { out.append(Character(scalar)) }
                else { out += "&" + body + ";" }
            } else {
                out += "&" + body + ";"
            }
            i = s.index(after: semi)
        }
        return out
    }

    /// Drops whole elements, contents and all. An element left unclosed keeps what follows it.
    private static func removeElements(_ html: String, tags: [String]) -> String {
        var s = html
        for tag in tags {
            var out = ""
            var rest = Substring(s)
            while let open = rest.range(of: "<" + tag, options: .caseInsensitive) {
                out += rest[..<open.lowerBound]
                let after = rest[open.upperBound...]
                guard let close = after.range(of: "</" + tag + ">", options: .caseInsensitive) else {
                    rest = after
                    break
                }
                rest = after[close.upperBound...]
            }
            out += rest
            s = out
        }
        return s
    }

    private static func removeComments(_ html: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let open = rest.range(of: "<!--") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else {
                rest = rest[open.upperBound...]
                break
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }
}

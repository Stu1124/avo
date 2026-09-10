// deps: Avo/Notch/MdParser.swift
import Foundation

@main
struct MdParserTests {
    // MARK: - Helpers

    static func paragraphs(_ blocks: [MdBlock]) -> [String] {
        blocks.compactMap { if case .paragraph(let t) = $0 { return t } else { return nil } }
    }

    static func headings(_ blocks: [MdBlock]) -> [(Int, String)] {
        blocks.compactMap { if case .heading(let l, let t) = $0 { return (l, t) } else { return nil } }
    }

    /// Runs the parser on a background thread so a stalled loop fails the test instead of hanging it.
    static func parseWithDeadline(_ source: String, seconds: Double, _ label: String) -> [MdBlock] {
        final class Box: @unchecked Sendable { var value: [MdBlock] = [] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = MdParser.parse(source)
            done.signal()
        }
        precondition(done.wait(timeout: .now() + seconds) == .success, "MdParser.parse did not finish: \(label)")
        return box.value
    }

    static func main() {
        // A bare `#`, a hashtag and a hex colour are body text, not headings — and none of them
        // may stall the paragraph collector.
        for source in ["#", "#hashtag", "#378FFF", "####### x", "#\n#\n#"] {
            let blocks = parseWithDeadline(source, seconds: 5, source.debugDescription)
            precondition(headings(blocks).isEmpty, "\(source.debugDescription) must not parse as a heading")
            precondition(!paragraphs(blocks).isEmpty, "\(source.debugDescription) must survive as paragraph text")
        }
        precondition(paragraphs(parseWithDeadline("#378FFF", seconds: 5, "hex")) == ["#378FFF"], "The `#` is part of the text")
        precondition(paragraphs(parseWithDeadline("####### x", seconds: 5, "seven")) == ["####### x"], "Seven hashes is not a heading")

        // A `#` line in the middle of a paragraph is absorbed, not treated as a break.
        precondition(paragraphs(parseWithDeadline("alpha\n#tag\nbeta", seconds: 5, "inline hash")) == ["alpha #tag beta"])

        // A streamed buffer that ends mid-heading terminates.
        let streamed = parseWithDeadline("Here is a thought.\n\n#", seconds: 5, "streamed")
        precondition(paragraphs(streamed) == ["Here is a thought.", "#"], "Got \(paragraphs(streamed))")

        // Every prefix of a streaming reply must terminate and never lose the opening text.
        let reply = "Intro line\n\n# Real heading\n\nBody #1 with a #hash\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n"
        for length in 0...reply.count {
            let prefix = String(reply.prefix(length))
            let blocks = parseWithDeadline(prefix, seconds: 5, "prefix \(length)")
            if length >= 10 { precondition(!blocks.isEmpty, "prefix \(length) produced nothing") }
        }

        // Normal headings still work, and level is clamped to 4.
        let h = headings(parseWithDeadline("# One\n## Two\n### Three\n###### Six", seconds: 5, "headings"))
        precondition(h.count == 4, "Got \(h.count) headings")
        precondition(h[0] == (1, "One") && h[1] == (2, "Two") && h[2] == (3, "Three"))
        precondition(h[3].0 == 4 && h[3].1 == "Six", "Level clamps to 4")
        precondition(headings(parseWithDeadline("#NoSpace", seconds: 5, "nospace")).isEmpty)

        // Lists, ordered and unordered, with continuation lines.
        let lists = parseWithDeadline("- alpha\n- beta\n  wrapped\n\n1. first\n2. second", seconds: 5, "lists")
        var unordered: [String] = [], ordered: [String] = []
        for b in lists {
            if case .list(let isOrdered, let items) = b { if isOrdered { ordered = items } else { unordered = items } }
        }
        precondition(unordered == ["alpha", "beta wrapped"], "Got \(unordered)")
        precondition(ordered == ["first", "second"], "Got \(ordered)")

        // A `*` run is a thematic break, not a one-item list.
        var breaks = 0
        for b in parseWithDeadline("***\n\n---\n\n___", seconds: 5, "rules") { if case .thematicBreak = b { breaks += 1 } }
        precondition(breaks == 3, "Got \(breaks) thematic breaks")

        // Fenced code keeps its language and its interior verbatim, including `#` lines.
        let fenced = parseWithDeadline("```python\n# a comment\nprint(1)\n```", seconds: 5, "fence")
        guard case .code(let lang, let code) = fenced.first else { preconditionFailure("Expected a code block") }
        precondition(lang == "python" && code == "# a comment\nprint(1)", "Got \(String(describing: lang)) / \(code)")

        // An unterminated fence still terminates the parse and keeps the body.
        let openFence = parseWithDeadline("```\nstill typing", seconds: 5, "open fence")
        guard case .code(_, let openCode) = openFence.first else { preconditionFailure("Expected a code block") }
        precondition(openCode == "still typing")

        // Blockquotes and math blocks.
        let quoted = parseWithDeadline("> one\n> two", seconds: 5, "quote")
        guard case .blockquote(let qt) = quoted.first else { preconditionFailure("Expected a blockquote") }
        precondition(qt == "one two", "Got \(qt)")
        let math = parseWithDeadline("$$ a + b $$", seconds: 5, "math")
        guard case .mathBlock(let latex) = math.first else { preconditionFailure("Expected a math block") }
        precondition(latex == "a + b", "Got \(latex)")

        // 10k lines, all of them the pathological `#`, finish well inside a second.
        let big = Array(repeating: "#", count: 10_000).joined(separator: "\n")
        let started = Date()
        let bigBlocks = parseWithDeadline(big, seconds: 5, "10k")
        let elapsed = Date().timeIntervalSince(started)
        precondition(bigBlocks.count == 1, "10k contiguous `#` lines collapse into one paragraph, got \(bigBlocks.count)")
        precondition(elapsed < 1.0, "10k lines took \(elapsed)s")

        // 10k mixed lines too, so the fast path is not just the paragraph collector.
        var mixed: [String] = []
        for n in 0..<2_000 { mixed += ["# Heading \(n)", "- item \(n)", "", "text #\(n)", ""] }
        let mixedStarted = Date()
        let mixedBlocks = parseWithDeadline(mixed.joined(separator: "\n"), seconds: 5, "10k mixed")
        let mixedElapsed = Date().timeIntervalSince(mixedStarted)
        precondition(mixedBlocks.count == 6_000, "Got \(mixedBlocks.count) blocks")
        precondition(mixedElapsed < 1.0, "10k mixed lines took \(mixedElapsed)s")

        print("PASS: heading recognition, hash-prefixed body text, streamed prefixes, lists, fences, quotes, math, 10k-line throughput")
    }
}

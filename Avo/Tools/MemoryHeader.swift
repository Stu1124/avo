import Foundation

/// The header block at the top of the memory file, and the one-time rewrite of a header written by a
/// previous version. Pure and Foundation-only so it can be tested standalone.
///
/// The rewrite replaces the header block *only*. Anything a user typed between the old header and their
/// first memory line is theirs, not ours, and is carried across untouched.
enum MemoryHeader {
    static let current = """
    # Avo memory

    Facts, links, and preferences the user asked Avo to remember. One line each, newest at the bottom. Avo edits this file itself via the `remember` and `forget` tools.

    ---
    """

    /// The file with its header block replaced, or nil when there is nothing to do — the header is already
    /// current, the file is empty, or it does not open with a heading and so has no header to replace.
    static func rewrite(_ text: String) -> String? {
        guard !text.isEmpty, !text.hasPrefix(current) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        func trimmed(_ i: Int) -> String { lines[i].trimmingCharacters(in: .whitespaces) }

        // The heading has to be the first thing in the file. A `# ` line further down belongs to the
        // memories, not to a header, and must not be swallowed.
        var i = 0
        while i < lines.count, trimmed(i).isEmpty { i += 1 }
        guard i < lines.count, trimmed(i).hasPrefix("# ") else { return nil }

        // Heading, then the description paragraph, then an optional `---` rule. An entry line ends the
        // block early: older headers had no blank line before the first memory.
        i += 1
        while i < lines.count, trimmed(i).isEmpty { i += 1 }
        while i < lines.count, !trimmed(i).isEmpty, !trimmed(i).hasPrefix("- ") { i += 1 }
        var rule = i
        while rule < lines.count, trimmed(rule).isEmpty { rule += 1 }
        if rule < lines.count, trimmed(rule) == "---" { i = rule + 1 }
        while i < lines.count, trimmed(i).isEmpty { i += 1 }

        let rest = lines[i...].joined(separator: "\n")
        let out = current + "\n" + rest
        return out == text ? nil : out
    }
}

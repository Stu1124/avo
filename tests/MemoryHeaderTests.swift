// deps: Avo/Tools/MemoryHeader.swift
import Foundation

// Pure header-block rewrite for the memory file. The point of the exercise: replace the header a
// previous version wrote, and *only* the header — every other line in the file survives untouched,
// including prose a user typed between the header and their first memory.

@main
struct MemoryHeaderTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if !ok { failures += 1; print("  x \(label)") }
    }

    static func checkEqual(_ label: String, _ got: String?, _ want: String?) {
        guard got != want else { return }
        failures += 1
        print("  x \(label)\n    got:  \(got.map { "\"\($0)\"" } ?? "nil")\n    want: \(want.map { "\"\($0)\"" } ?? "nil")")
    }

    static func main() {
        let current = MemoryHeader.current

        // A file already carrying the current header is left alone.
        checkEqual("current header is a no-op", MemoryHeader.rewrite(current + "\n- [2026-01-01] a thing"), nil)

        // An empty file is left alone; the store writes a fresh header itself.
        checkEqual("empty file is a no-op", MemoryHeader.rewrite(""), nil)
        checkEqual("blank file is a no-op", MemoryHeader.rewrite("\n\n"), nil)

        // No heading line: nothing here is a header, so nothing is replaced.
        checkEqual("no heading is a no-op", MemoryHeader.rewrite("- [2026-01-01] a thing\n- [2026-01-02] another"), nil)

        // The classic old header: heading, description paragraph, rule. Entries survive verbatim.
        let old = """
        # Previous memory

        Facts, links, and preferences someone asked the app to remember. One line each.

        ---
        - [2026-01-01] a thing
        - [2026-01-02] another
        """
        checkEqual("old header replaced, entries kept", MemoryHeader.rewrite(old), current + """

        - [2026-01-01] a thing
        - [2026-01-02] another
        """)

        // Text the user typed between the old header and the first entry is preserved.
        let withNote = """
        # Previous memory

        Facts, links, and preferences someone asked the app to remember. One line each.

        ---
        Note to self: keep the work links at the bottom.

        - [2026-01-01] a thing
        """
        checkEqual("non-header text between header and entries survives", MemoryHeader.rewrite(withNote), current + """

        Note to self: keep the work links at the bottom.

        - [2026-01-01] a thing
        """)

        // An older header with no `---` rule: the description goes, the entry stays.
        let noRule = """
        # Previous memory
        Facts, links, and preferences someone asked the app to remember.
        - [2026-01-01] a thing
        """
        checkEqual("header without a rule", MemoryHeader.rewrite(noRule), current + "\n- [2026-01-01] a thing")

        // A heading with no entries at all still gets the new header and loses nothing else.
        checkEqual("heading only", MemoryHeader.rewrite("# Previous memory\n\nSome description.\n"), current + "\n")

        // Rewriting is idempotent: a rewritten file is a no-op on the next pass.
        if let once = MemoryHeader.rewrite(old) {
            checkEqual("idempotent", MemoryHeader.rewrite(once), nil)
        } else {
            failures += 1
            print("  x idempotent: first rewrite returned nil")
        }

        // The header names the current app.
        check("header names Avo", current.hasPrefix("# Avo memory"))

        if failures == 0 {
            print("PASS: memory header replacement, preserved text, idempotence")
        } else {
            print("FAIL: MemoryHeaderTests (\(failures))")
            exit(1)
        }
    }
}

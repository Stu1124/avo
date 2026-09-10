// deps: Avo/Voice/SpeechText.swift
import Foundation

@main
struct SpeechTextTests {
    static func check(_ input: String, _ expected: String, _ what: String) {
        let got = SpeechText.plain(input)
        precondition(got == expected, "\(what): expected \(expected.debugDescription), got \(got.debugDescription)")
    }

    static func main() {
        // The three cases the log caught being read aloud verbatim.
        check("The **trendline** is up.", "The trendline is up.", "bold")
        check("That cell shows `#DIV/0!`.", "That cell shows #DIV/0!.", "code span")
        check("Rates fell ([Reuters](https://example.com/a)).", "Rates fell (Reuters).", "citation link")

        // A link with no text takes its empty parentheses with it.
        check("Done ([](https://example.com)).", "Done .", "empty link")

        // Italics, underscores and headings.
        check("It was *quite* good.", "It was quite good.", "italic")
        check("__Really__ good.", "Really good.", "bold underscore")
        check("## Summary\nTwo lines.", "Summary\nTwo lines.", "heading")

        // An identifier keeps its underscores: they are not emphasis.
        check("Call send_email now.", "Call send_email now.", "snake_case survives")

        // Lists and quotes lose their markers, not their words.
        check("- one\n- two", "one\ntwo", "bullets")
        check("> quoted line", "quoted line", "blockquote")

        // A bare URL becomes a word instead of a spelled-out address.
        check("See https://example.com/x?y=1 for more.", "See link for more.", "bare url")

        // Fences go, the code inside stays speakable.
        check("```swift\nlet x = 1\n```", "let x = 1", "fenced code")

        // Whitespace is tidied, and nothing is left dangling.
        check("  Spaced    out.  ", "Spaced out.", "whitespace")
        check("", "", "empty")

        print("PASS: bold, code spans, links, headings, lists, quotes, urls, fences, whitespace")
    }
}

// deps: Avo/Support/LogRedaction.swift
import Foundation

private var failures = 0
private func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; FileHandle.standardError.write(Data("  ✗ \(what)\n".utf8)) }
}
private func check(_ got: String, _ want: String, _ what: String) {
    if got != want {
        failures += 1
        FileHandle.standardError.write(Data("  ✗ \(what)\n    got:  \(got)\n    want: \(want)\n".utf8))
    }
}

@main
enum LogRedactionTests {
    static func main() {
        transcriptsGo()
        toolArgumentsGoAndTheNameStays()
        multiLinePayloadsGoWhole()
        ordinaryLinesStay()
        if failures == 0 {
            print("PASS: transcript redaction, tool arguments, multi-line payloads, untouched lines")
        } else {
            FileHandle.standardError.write(Data("FAIL: \(failures) check(s)\n".utf8))
            exit(1)
        }
    }

    static func transcriptsGo() {
        let log = """
        2026-09-09T10:00:00.000Z INFO Turn start: book me a table at eight
        2026-09-09T10:00:01.000Z INFO Listen: transcript 'book me a table at eight'
        2026-09-09T10:00:02.000Z INFO WakeWord: utterance 'avo what is my password'
        2026-09-09T10:00:03.000Z INFO Turn done: Your table is booked for eight, under Dana.
        """
        let out = LogRedaction.apply(to: log)
        check(!out.contains("table"), "transcript text is gone from Turn start / Listen")
        check(!out.contains("password"), "wake-word utterance is gone")
        check(!out.contains("Dana"), "the spoken reply is gone from Turn done")
        check(out.contains("Turn start: [redacted]"), "the Turn start line still says a turn happened")
        check(out.contains("Turn done: [redacted]"), "the Turn done line still says the turn ended")
        check(out.split(separator: "\n").count == 4, "one line in, one line out")
    }

    static func toolArgumentsGoAndTheNameStays() {
        let log = "2026-09-09T10:00:00.000Z INFO Tool call: send_message {\"to\":\"Dana\",\"body\":\"running late\"}"
        check(LogRedaction.apply(to: log),
              "2026-09-09T10:00:00.000Z INFO Tool call: send_message [redacted]",
              "the tool name survives, the arguments do not")
    }

    static func multiLinePayloadsGoWhole() {
        // A quotation with a newline in it reaches the file as several lines; only the first carries
        // the marker, and cutting line by line used to leave the rest of it in the export.
        let log = """
        2026-09-09T10:00:00.000Z INFO Tool call: write_file {"path":"a.txt","text":"line one
        line two, still secret
        line three"}
        2026-09-09T10:00:01.000Z INFO Listen: transcript 'first line
        second line of what I said'
        2026-09-09T10:00:02.000Z INFO Registered 88 tools
        """
        let out = LogRedaction.apply(to: log)
        check(!out.contains("still secret"), "a wrapped tool argument is dropped with its first line")
        check(!out.contains("second line of what I said"), "a wrapped transcript is dropped whole")
        check(out.contains("Registered 88 tools"), "the next entry ends the redaction")
        check(out.split(separator: "\n").count == 3, "three entries in, three lines out")
    }

    static func ordinaryLinesStay() {
        let log = """
        2026-09-09T10:00:00.000Z INFO Avo launching
        2026-09-09T10:00:00.100Z WARN MCP[linear]: discovery failed
          continuation of a warning
        """
        check(LogRedaction.apply(to: log), log, "nothing else in the log is touched")
        check(LogRedaction.apply(to: ""), "", "an empty log stays empty")
        check(!LogRedaction.startsEntry("  indented continuation"), "a continuation is not an entry")
        check(LogRedaction.startsEntry("2026-09-09T10:00:00.000Z INFO x"), "a stamped line is an entry")
    }
}

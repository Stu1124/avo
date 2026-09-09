import Foundation

/// Decides what the diagnostics export keeps out of `avo.log`. Pure Foundation and free of the rest
/// of the app on purpose: this is the code that decides what leaves the machine, so it is unit-tested
/// (`tests/LogRedactionTests.swift`) rather than reasoned about.
///
/// Two kinds of line quote the turn. The spoken markers carry what was said and what Avo said back —
/// `Turn done:` is the spoken reply, verbatim. `Tool call:` carries the arguments the model built from
/// it — a message body, a search query, a path — which is user content just as much as a transcript.
enum LogRedaction {
    /// Log lines that quote the user, and the marker each one's text follows.
    static let spokenMarkers = ["Turn start:", "Turn done:", "Listen: transcript", "WakeWord: utterance"]

    /// The tool-call line. The tool's name survives the redaction; its arguments do not.
    static let toolCallMarker = "Tool call:"

    /// True for the first line of a log entry, which `Log` stamps with an ISO 8601 instant. Anything
    /// else is a continuation of the entry above it: a quotation with a newline in it reaches the file
    /// as several lines, and only the first carries the marker. Without this, redacting line by line
    /// cut the first line of a transcript and left the rest of it in the export.
    static func startsEntry(_ line: Substring) -> Bool {
        guard line.count >= 20 else { return false }
        let head = line.prefix(11)                       // "2026-09-09T"
        return head.last == "T" && head.dropLast().allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// Cuts every marked entry at its marker — so the line still says a turn happened, or which tool
    /// ran, and no longer says with what — and drops the continuation lines carrying the rest of it.
    /// Nothing else in the log is touched.
    static func apply(to log: String) -> String {
        var out: [String] = []
        var droppingContinuation = false
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            guard startsEntry(line) else {
                if !droppingContinuation { out.append(String(line)) }
                continue
            }
            droppingContinuation = false
            if let marker = spokenMarkers.first(where: { line.contains($0) }),
               let range = line.range(of: marker) {
                out.append(line[line.startIndex..<range.upperBound] + " [redacted]")
                droppingContinuation = true
            } else if let range = line.range(of: toolCallMarker) {
                let name = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                out.append(line[line.startIndex..<range.upperBound] + " \(name) [redacted]")
                droppingContinuation = true
            } else {
                out.append(String(line))
            }
        }
        return out.joined(separator: "\n")
    }
}

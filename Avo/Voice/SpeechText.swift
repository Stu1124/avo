import Foundation

/// Markdown → speakable text. The model answers in light Markdown (bold, code spans, citation links);
/// spoken output should carry the words only. Log evidence: "**trendline**", "`#DIV/0!`" and "([]())" were sent verbatim.
enum SpeechText {
    static func plain(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"```[A-Za-z0-9_+-]*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "")
        // [text](url) → text; a link with no text vanishes, as does the "( )" the model wraps citations in.
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![A-Za-z0-9])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![A-Za-z0-9])"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*>\s?"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://[^\s)\]]+"#, with: "link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

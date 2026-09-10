import Foundation

/// Cheap local intent checks so "yes" / "no" / "think hard" never need a model round trip.
///
/// Each of these decides something on the user's behalf without asking the model, so the cost of a
/// wrong answer is real: a stray `confirmDecision` sends an email nobody approved. They are kept
/// here, free of AppKit and of the runtime, so `tests/QuickIntentTests.swift` can pin the exact
/// wording that counts as yes, as no, and as neither.
enum QuickIntent {
    /// A whole utterance that is nothing but agreement or refusal. Anything else — including an
    /// edit like "make it 7:30" — returns nil and goes to the model, which is what lets the user
    /// change a confirmation card by voice instead of accidentally confirming it.
    static func confirmDecision(_ t: String) -> ConfirmationCard.Decision? {
        let s = t.lowercased().trimmingCharacters(in: .punctuationCharacters).trimmingCharacters(in: .whitespaces)
        let yes = ["yes", "yeah", "yep", "yup", "confirm", "send", "send it", "do it", "go", "go ahead", "sure", "ok", "okay", "looks good", "perfect", "yes send it", "yes do it", "correct", "that's right", "ship it"]
        let no = ["no", "nope", "cancel", "don't", "dont", "stop", "never mind", "nevermind", "no cancel", "scrap it", "not now", "abort"]
        if yes.contains(s) { return .confirm([:]) }
        if no.contains(s) { return .cancel }
        return nil
    }

    /// Writing requests get the full voice skill in the instructions; everything else gets the summary.
    static func wantsWriting(_ t: String) -> Bool {
        let s = t.lowercased()
        let cues = ["write", "draft", "reply", "respond", "email", "text ", "message", "compose", "rewrite", "reword",
                    "shorten", "edit this", "fix this", "caption", "post", "dm ", "say to", "tell ", "essay", "letter", "note to"]
        return cues.contains { s.contains($0) }
    }

    static func wantsDeep(_ t: String) -> Bool {
        let s = t.lowercased()
        return s.contains("think hard") || s.contains("think harder") || s.contains("think deeply") || s.contains("deep mode") || s.contains("take your time")
    }
}

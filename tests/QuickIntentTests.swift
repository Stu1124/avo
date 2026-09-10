// deps: Avo/Agent/QuickIntent.swift Avo/Cards/CardModels.swift
import Foundation

@main
struct QuickIntentTests {
    static func isConfirm(_ t: String) -> Bool {
        if case .confirm = QuickIntent.confirmDecision(t) { return true }
        return false
    }
    static func isCancel(_ t: String) -> Bool {
        if case .cancel = QuickIntent.confirmDecision(t) { return true }
        return false
    }

    static func main() {
        // Plain agreement, with the punctuation and casing speech recognition actually produces.
        for yes in ["yes", "Yes.", "yep", "send it", "Go ahead!", "ok", "looks good", "ship it", "  sure  "] {
            precondition(isConfirm(yes), "\(yes.debugDescription) should confirm")
        }
        // Plain refusal.
        for no in ["no", "Nope.", "cancel", "never mind", "don't", "Stop!", "not now", "abort"] {
            precondition(isCancel(no), "\(no.debugDescription) should cancel")
        }

        // An edit is not an answer. These have to reach the model, or saying "make it 7:30" would
        // send the card as it stands.
        for neither in ["make it 7:30", "change it to Thursday", "yes but move it to 4pm", "send it to Kai instead",
                        "no rush, tomorrow is fine", "okay so what about Friday", "", "   "] {
            precondition(QuickIntent.confirmDecision(neither) == nil, "\(neither.debugDescription) should reach the model")
        }

        // Writing requests pull in the full voice skill.
        precondition(QuickIntent.wantsWriting("draft a reply to Maya"))
        precondition(QuickIntent.wantsWriting("Write an email to the landlord"))
        precondition(QuickIntent.wantsWriting("shorten this paragraph"))
        precondition(!QuickIntent.wantsWriting("what's on my calendar tomorrow?"))
        precondition(!QuickIntent.wantsWriting("play something on Spotify"))

        // Deep mode is opt-in by phrase.
        precondition(QuickIntent.wantsDeep("think hard about this"))
        precondition(QuickIntent.wantsDeep("Take your time and check the math"))
        precondition(!QuickIntent.wantsDeep("what time is it"))

        print("PASS: yes/no answers, edits reaching the model, writing and deep-mode cues")
    }
}

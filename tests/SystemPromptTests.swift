// deps: Avo/Agent/SystemPromptRender.swift
import Foundation

@main
struct SystemPromptTests {
    static func main() {
        let anon = SystemPromptRender.render(userName: "", writingStyle: "STYLE", contexts: [], memory: "", includeVoice: true)
        precondition(anon.contains("the user's voice assistant"), "empty name falls back to 'the user'")
        precondition(anon.contains("the notch of their Mac"), "no gendered pronoun")
        precondition(anon.hasPrefix("You are Avo, the user's voice assistant"), "nothing personal ahead of the persona line")
        precondition(!anon.contains("<context "), "no context block when there are no context files")

        let contexts = [(name: "notes.md", text: "N1"), (name: "rules.md", text: "R2")]
        let named = SystemPromptRender.render(userName: "Sam", writingStyle: "STYLE", contexts: contexts, memory: "- [2026-01-01] likes tea", includeVoice: true)
        precondition(named.contains("Sam's voice assistant"), "name is used")
        precondition(named.contains("<context name=\"notes.md\">\nN1\n</context>"), "context block format")
        precondition(named.range(of: "N1")!.lowerBound < named.range(of: "R2")!.lowerBound, "contexts keep order")
        precondition(named.contains("<voice_rules>\nSTYLE\n</voice_rules>"), "writing style goes in the voice slot")
        precondition(named.contains("likes tea"), "memory is included")

        // A name already ending in "s" takes a bare apostrophe.
        let plural = SystemPromptRender.render(userName: "Chris", writingStyle: "S", contexts: [], memory: "", includeVoice: true)
        precondition(plural.contains("Chris' voice assistant"), "possessive of a name ending in s")

        let noVoice = SystemPromptRender.render(userName: "Sam", writingStyle: "STYLE", contexts: [], memory: "", includeVoice: false)
        precondition(!noVoice.contains("STYLE") && noVoice.contains("<voice_rules>"), "voice rules omitted but slot kept for cache stability")

        precondition(named == SystemPromptRender.render(userName: "Sam", writingStyle: "STYLE", contexts: contexts, memory: "- [2026-01-01] likes tea", includeVoice: true), "byte-stable")
        print("PASS: persona name fallback, context files, voice slot, memory, stability")
    }
}

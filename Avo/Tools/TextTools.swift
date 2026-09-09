import AppKit
import CoreGraphics
import Foundation

/// Text actions: rewrite the selection, stage a reply or an AI prompt, paste, copy, screen access.
/// The descriptions here are the model's routing rules: what each tool does and when to reach for it.
enum TextTools {
    static func all() -> [Tool] {
        [EditTextTool(), DraftReplyTool(), CreatePromptTool(), PasteTextTool(), CopyToClipboardTool(), EnableScreenAccessTool()]
            + LocationTools.all()
    }

    static let group = "Text"
    static let icon = "text.cursor"

    /// Clipboard staging shared by draft_reply and create_prompt.
    @MainActor
    static func stage(_ text: String, title: String, hint: String) -> CardKind {
        TextInjector.copyOnly(text)
        var card = DraftCard(id: UUID(), title: title, text: text, hint: hint)
        card.onChange = { edited in TextInjector.copyOnly(edited) }
        return .draft(card)
    }
}

// MARK: - edit_text

private struct EditTextTool: Tool {
    let name = "edit_text"
    let description = """
    Swaps whatever the user has highlighted for wording you supply. Reach for it ONLY where the instruction is to CHANGE \
    that highlighted passage — tighten it, stretch it, reword, translate, correct, polish, or transform it some other way. \
    The highlighted passage reaches you as context, and `new_text` has to carry the FULL finished replacement: NOT a diff, \
    not a summary, not a note about what you altered, because Avo types it straight over the selection in whichever app is \
    frontmost. A QUESTION about the highlighted text — is the tone right, what does it mean, is the wording any good — is \
    no rewrite request: answer it in conversation and leave the selection alone.
    """
    let params = [ToolParam("new_text", "string", "Everything that should replace what the user has highlighted, written out in full — supply the finished passage rather than a diff or a list of edits.", required: true)]
    let statusLabel = "Rewriting"
    let statusIcon = TextTools.icon
    let group = TextTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let text = JSON.string(args["new_text"]), !text.isEmpty else {
            return .fail("new_text is required", guidance: "Call edit_text again with the complete replacement text.")
        }
        let outcome = await TextInjector.replaceSelection(with: text)
        var json: [String: Any] = ["ok": true, "pasted": outcome.pasted, "copied": true, "chars": text.count, "note": outcome.note]
        if let app = outcome.app { json["app"] = app }
        var cards: [CardKind] = []
        if !outcome.pasted {
            json["guidance"] = "Avo could only copy the text. Tell the user in one line to press ⌘V over their selection, and that Accessibility access is needed for automatic replacement."
            cards.append(await TextTools.stage(text, title: "Rewritten text", hint: "Copied. Select your text and press ⌘V."))
        }
        return .ok(json, cards: cards)
    }
}

// MARK: - draft_reply

private struct DraftReplyTool: Tool {
    let name = "draft_reply"
    let description = """
    Writes the REPLY to a chat, email, comment, DM, post, or message the user is presently looking at, and puts it in \
    front of them to check over. One situation ONLY: they have told you to respond, answer, or write back ('reply to this', \
    'tell her I'm in', 'say I'll be there'). What comes out is a message addressed to a person and nothing else. Do \
    NOT call it for typing a search query, looking something up, navigating, opening anything, entering an address, or \
    filling a form field: 'search for this', 'look that up', 'find me a flight home', 'go to her profile' and their kin send \
    nothing to anybody, so this is the WRONG tool for every one of them. Do NOT call it either when the user puts a QUESTION \
    to you about the conversation on screen instead of telling you to answer it ('what do you make of this?', 'sum up this \
    chat', 'what am I looking at') — handle those yourself in conversation. YOU compose the `text`: read the thread off the attached capture of the user's screen, which also records \
    whatever they drew or pointed at, so use that to settle WHICH message is meant, then write the reply out in full, in \
    their voice and the thread's language. It is NOT pasted and NOT sent anywhere by you — the reply surfaces as an EDITABLE \
    card in the Avo panel and lands on the clipboard, and the user drops it into their app with ⌘V. Call it ONCE. Do NOT use \
    it to change text the user highlighted; that work is edit_text's, NEVER this tool's. Close on ONE short line (say, 'Reply's ready — ⌘V drops it \
    in.') and never read the draft back to them.
    """
    let params = [ToolParam("text", "string", "The finished reply, ready for the user to look over. Compose it yourself out of what the screen or conversation shows; hand over the actual message in full, never a stand-in or a description of what it would say.", required: true)]
    let statusLabel = "Drafting"
    let statusIcon = "square.and.pencil"
    let group = TextTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let text = JSON.string(args["text"]), !text.isEmpty else {
            return .fail("text is required", guidance: "Call draft_reply again with the full reply text.")
        }
        let card = await TextTools.stage(text, title: "Reply", hint: "Copied. Click into the reply box and press ⌘V.")
        return .ok(["ok": true, "staged": true, "copied": true, "pasted": false, "chars": text.count,
                    "note": "Reply is staged in an editable card and copied to the clipboard. Not sent. Tell the user in one short line to paste it with ⌘V."],
                   cards: [card])
    }
}

// MARK: - create_prompt

private struct CreatePromptTool: Tool {
    let name = "create_prompt"
    let description = """
    Builds a finished, ready-to-paste PROMPT for some other AI — Claude Code, Cursor, Codex, ChatGPT, Claude, an image \
    model, an agent — out of what the user said together with what they marked on screen. Its trigger is the literal request to \
    make one ('write me a prompt for this', 'turn this into a prompt for Claude about the designs'), and ONLY those words. \
    Screen context NEVER triggers it: people ring things mostly to POINT at whatever they are discussing, so a capture — \
    even one showing Claude, ChatGPT, or Cursor — does NOT mean a prompt is wanted, and 'what is this', 'describe what you \
    see', 'sum up this chat' are ordinary screen questions — answer them yourself and do NOT call this tool for them. Anything the user ringed while speaking was captured and \
    attached to this turn, each window carrying a numbered blue badge in its corner. YOU write `prompt`: put the user's ask \
    cleanly to the AI that will receive it and then STOP, because their words fix the scope. Stay MINIMAL — requirements, \
    constraints, edge cases and steps they never mentioned must NOT be invented, so a one-sentence ask yields a one- or \
    two-sentence prompt. Cite a capture inline as [img N] — lowercase img, exactly one space ahead of the number, as in \
    'match the card style in [img 2]' — wherever its content bears on the ask, and let the picture supply the visual detail \
    rather than describing it. Address the receiving AI in the second person, imperative; NEVER write to the user, and \
    NEVER name Avo. Sentences beat headers and bullets unless the ask genuinely has parts, and filler has no place. The finished text \
    is NOT pasted and NOT sent anywhere by you — it surfaces as an EDITABLE card in the Avo panel, goes onto the \
    clipboard, and a copy is filed alongside the captures in the prompts folder. ONCE per prompt — a revision means calling \
    again with the COMPLETE new text, [img N] tags intact. Prompts must NOT go through draft_reply. Do not read the prompt \
    back; close on ONE short line that makes the next move obvious (say, 'On your clipboard — paste it into Claude.').
    """
    let params = [ToolParam("prompt", "string", "The finished prompt, ready to hand off. Address it to the AI that will receive it, and point at the attached captures wherever they carry weight using the form [img N] — lowercase img, exactly one space ahead of the number. Give the whole prompt, not an outline or a stand-in.", required: true)]
    let statusLabel = "Writing prompt"
    let statusIcon = "sparkles"
    let group = TextTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let prompt = JSON.string(args["prompt"]), !prompt.isEmpty else {
            return .fail("prompt is required", guidance: "Call create_prompt again with the complete prompt text.")
        }
        let card = await TextTools.stage(prompt, title: "Prompt", hint: "Copied to your clipboard. Paste it into Claude, ChatGPT, or Cursor.")
        var json: [String: Any] = ["ok": true, "staged": true, "copied": true, "pasted": false, "chars": prompt.count]
        let saved = save(prompt: prompt, attachments: ctx.attachments)
        json["folder"] = saved.folder
        if !saved.images.isEmpty {
            json["image_paths"] = saved.images
            json["images"] = saved.images.count
            json["note"] = "Prompt copied to the clipboard and staged in an editable card. The \(saved.images.count) attached screenshot(s) were saved next to it in \(saved.folder) — mention that the images are in that folder if the user needs to attach them in their AI app."
        } else {
            json["note"] = "Prompt copied to the clipboard and staged in an editable card. Saved a copy in \(saved.folder). Finish with one short line telling the user to paste it."
        }
        return .ok(json, cards: [card])
    }

    /// Writes prompt.md plus copies of the gesture screenshots into ~/Library/Application Support/Avo/prompts/<timestamp>/.
    private func save(prompt: String, attachments: [String]) -> (folder: String, images: [String]) {
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = Paths.appSupport.appendingPathComponent("prompts/\(fmt.string(from: Date()))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var copied: [String] = []
        for (i, src) in attachments.enumerated() where fm.fileExists(atPath: src) {
            let ext = URL(fileURLWithPath: src).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: src).pathExtension
            let dst = dir.appendingPathComponent("img-\(i + 1).\(ext)")
            try? fm.removeItem(at: dst)
            do { try fm.copyItem(at: URL(fileURLWithPath: src), to: dst); copied.append(dst.path) }
            catch { Log.warn("create_prompt: could not copy \(src): \(error.localizedDescription)") }
        }
        var md = "# Prompt\n\n\(prompt)\n"
        if !copied.isEmpty {
            md += "\n## Attachments\n" + copied.enumerated().map { "- [img \($0.offset + 1)] \($0.element)" }.joined(separator: "\n") + "\n"
        }
        try? md.write(to: dir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        return (dir.path, copied)
    }
}

// MARK: - paste_text

private struct PasteTextTool: Tool {
    let name = "paste_text"
    let description = """
    Type/paste literal text at the user's cursor in the app they are working in — a search query, a URL, a form field value, \
    a snippet they dictated ('type this into the field', 'put my email in there', 'paste the address'). Avo copies the text \
    and presses ⌘V in the frontmost app, so the user must already have the field focused. Use this for text going into a \
    field or box, NEVER for a message to a person (that is draft_reply), NEVER for rewriting text the user has selected \
    (that is edit_text), and NEVER for an AI prompt (that is create_prompt).
    """
    let params = [ToolParam("text", "string", "The exact text to paste at the cursor. Literal final text — no quotes, labels, or commentary around it.", required: true)]
    let statusLabel = "Pasting"
    let statusIcon = "doc.on.clipboard"
    let group = TextTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let text = JSON.string(args["text"]), !text.isEmpty else {
            return .fail("text is required", guidance: "Call paste_text again with the exact text to paste.")
        }
        let outcome = await TextInjector.paste(text)
        var json: [String: Any] = ["ok": true, "pasted": outcome.pasted, "copied": true, "chars": text.count, "note": outcome.note]
        if let app = outcome.app { json["app"] = app }
        if !outcome.pasted { json["guidance"] = "Avo could only copy the text. Tell the user in one line to press ⌘V, and that Accessibility access enables automatic pasting." }
        return .ok(json)
    }
}

// MARK: - copy_to_clipboard

private struct CopyToClipboardTool: Tool {
    let name = "copy_to_clipboard"
    let description = """
    Put text on the user's clipboard without pasting it anywhere ('copy that', 'copy this link', 'save that to my \
    clipboard'). Use it when the user wants something in hand to paste themselves later. Do NOT use it to reply to a person \
    (draft_reply), to rewrite selected text (edit_text), to write an AI prompt (create_prompt), or when they asked you to \
    actually put the text into a field (paste_text).
    """
    let params = [ToolParam("text", "string", "The exact text to place on the clipboard.", required: true)]
    let statusLabel = "Copying"
    let statusIcon = "doc.on.clipboard"
    let group = TextTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        guard let text = JSON.string(args["text"]), !text.isEmpty else {
            return .fail("text is required", guidance: "Call copy_to_clipboard again with the text to copy.")
        }
        await MainActor.run { TextInjector.copyOnly(text) }
        let glance = GlanceCard(id: UUID(), blocks: [.text("Copied")], source: "Clipboard", sourceIcon: "doc.on.clipboard")
        return .ok(["ok": true, "copied": true, "chars": text.count, "note": "On the clipboard. Confirm in one short line; do not repeat the text."],
                   cards: [.glance(glance)])
    }
}

// MARK: - enable_screen_access

private struct EnableScreenAccessTool: Tool {
    let name = "enable_screen_access"
    let description = """
    Switches Avo's screen access on, so that from the user's NEXT message onward a picture of their screen travels with \
    it. Call it ONLY for two reasons and no others: their request cannot be answered without sight of the screen ('read \
    this error', 'what's this on my screen', 'can you see what I'm looking at'), or they have asked outright for screen \
    access to be turned on. At most ONCE in a turn. Calling it flips the setting and either raises the macOS Screen \
    Recording prompt or opens the System Settings pane that governs it. It does NOT hand you the screen — even on success \
    you see NOTHING for the remainder of this turn, so NEVER describe or guess at what is displayed. Pass the result's \
    `guidance` along in a line or two: usually that access is now on, that the macOS permission needs granting if a dialog \
    appeared, and that they should put the question again.
    """
    let params: [ToolParam] = []
    let statusLabel = "Enabling screen access"
    let statusIcon = "rectangle.inset.filled.and.person.filled"
    let group = TextTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        let wasOn = await MainActor.run { () -> Bool in
            let was = Settings.shared.screenAwareness
            Settings.shared.screenAwareness = true
            return was
        }
        let granted = CGPreflightScreenCaptureAccess()
        var requested = false
        if !granted { requested = CGRequestScreenCaptureAccess() }
        let permission = granted ? "granted" : (requested ? "granted" : "needed")
        let guidance: String
        if granted {
            guidance = wasOn
                ? "Screen access was already on. You still cannot see this turn's screen — ask the user to say it again and the screenshot will be attached."
                : "Screen access is on now and the macOS permission is already granted. You cannot see the screen this turn — ask the user to repeat the question."
        } else if requested {
            guidance = "Screen access is on and macOS just granted Screen Recording. You cannot see the screen this turn — ask the user to repeat the question."
        } else {
            guidance = "Screen access is on, but macOS Screen Recording is still off. Tell the user to allow Avo in System Settings > Privacy & Security > Screen & System Audio Recording, then ask again."
        }
        return .ok(["ok": true, "screen_awareness": true, "was_enabled": wasOn, "permission": permission, "guidance": guidance])
    }
}

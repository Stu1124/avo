import AppKit
import ApplicationServices
import CoreGraphics

/// Pastes text into whatever app the user is actually working in.
///
/// The notch is a non-activating panel, so the user's app normally stays frontmost while Avo runs.
/// We read the frontmost app fresh at call time, re-activate it (unless it is Avo itself), synthesise
/// ⌘V, then put the user's old pasteboard back. Requires Accessibility; without it we only copy.
@MainActor
enum TextInjector {

    struct Outcome {
        /// True when ⌘V was actually synthesised into the target app.
        var pasted: Bool
        /// Target app name, when we could tell.
        var app: String?
        /// One-line explanation for the model / user.
        var note: String
    }

    /// Copy `text`, activate the frontmost non-Avo app, send ⌘V, restore the old pasteboard.
    @discardableResult
    static func paste(_ text: String) async -> Outcome {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            Log.warn("TextInjector: Accessibility not trusted, copied instead of pasting")
            return Outcome(pasted: false, app: NSWorkspace.shared.frontmostApplication?.localizedName,
                           note: "Accessibility permission is off, so Avo could not paste. The text is on the clipboard — press ⌘V to place it. Grant it in System Settings > Privacy & Security > Accessibility.")
        }

        let target = NSWorkspace.shared.frontmostApplication
        let isAvo = target?.bundleIdentifier == Bundle.main.bundleIdentifier
        if let target, !isAvo, !target.isActive {
            target.activate()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        sendCommandV()
        try? await Task.sleep(nanoseconds: 250_000_000)
        restore(saved, to: pb)

        let name = isAvo ? nil : target?.localizedName
        return Outcome(pasted: true, app: name,
                       note: name.map { "Pasted into \($0)." } ?? "Pasted at the cursor.")
    }

    /// Replacing a selection is the same gesture: ⌘V overwrites whatever is selected.
    @discardableResult
    static func replaceSelection(with text: String) async -> Outcome {
        await paste(text)
    }

    /// Clipboard only — no keystrokes, no app activation.
    static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - internals

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState(.permitLocalKeyboardEvents, state: .eventSuppressionStateSuppressionInterval)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).prefix(8).map { item in
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type), d.count < 4_000_000 { payload[type] = d }
            }
            return payload
        }
    }

    private static func restore(_ snap: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        let items: [NSPasteboardItem] = snap.compactMap { payload in
            guard !payload.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in payload { item.setData(data, forType: type) }
            return item
        }
        guard !items.isEmpty else { return }
        pb.writeObjects(items)
    }
}

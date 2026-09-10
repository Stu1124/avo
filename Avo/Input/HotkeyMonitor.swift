import Foundation
import AppKit
import Carbon.HIToolbox

/// Global fn (globe) key hold detection via CGEventTap. Also Control+Option hold as an alias and Escape to cancel.
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private enum TalkSource { case instantModifier, delayedModifier, functionKey }
    static let delayedModifierArmDelay: TimeInterval = 0.5
    private var activeTalkSource: TalkSource?
    private var instantModifierDown = false
    private var instantModifierSuppressed = false
    private var delayedModifierDown = false
    private var delayedModifierArmed = false
    private var delayedModifierSuppressed = false
    private var delayedModifierTimer: DispatchWorkItem?
    private var functionKeyDown = false
    private var functionKeySuppressed = false
    private var pressStart: Date?
    private var pendingTapWarning = false

    /// Configured from Settings.
    var talkKey = "fn" {
        didSet {
            guard talkKey != oldValue else { return }
            resetInputState(cancelActiveTalk: true)
        }
    }
    var composerShortcut = "optionSpace"
    var onComposer: (() -> Void)?
    var onPress: (() -> Void)?
    var onRelease: ((_ heldSeconds: TimeInterval) -> Void)?
    var onCancel: (() -> Void)?
    var onEscape: (() -> Void)?

    func start() {
        guard tap == nil else { return }
        // Mouse buttons are in the mask so a ⌘-click (or a click while a modifier is held) reads as a
        // chord and never opens the microphone.
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return me.handle(type: type, event: event)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: refcon) else {
            if !pendingTapWarning { Log.warn("Event tap failed: Input Monitoring permission missing; retrying every 3s") }
            pendingTapWarning = true
            // Permission is usually granted during onboarding, after launch: keep retrying until the tap installs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.tap == nil else { return }
                self.start()
            }
            return
        }
        pendingTapWarning = false
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        Log.info("Hotkey tap installed")
    }

    func stop() {
        resetInputState(cancelActiveTalk: false)
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }


    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if hasHeldTalkInput { cancelTalkForKeyChord() }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged {
            handleDelayedModifierChange(keyCode: key, flags: flags)
            cancelDelayedTalkForAdditionalModifier(keyCode: key, flags: flags)
            handleInstantModifierChange(flags: flags)
        } else if type == .keyDown || type == .keyUp {
            let fcode = talkKey == "f5" ? Int(kVK_F5) : (talkKey == "f6" ? Int(kVK_F6) : -1)
            if key == fcode {
                if type == .keyDown, !functionKeyDown {
                    functionKeyDown = true
                    if !functionKeySuppressed { beginTalk(from: .functionKey) }
                } else if type == .keyUp, functionKeyDown {
                    functionKeyDown = false
                    if activeTalkSource == .functionKey { finishTalk(from: .functionKey) }
                    functionKeySuppressed = false
                }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }

            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Composer shortcuts win over hold-to-talk. This is especially important when Right Command
            // is the talk key: an ordinary ⌘-based shortcut must never flash listening and close the notch.
            if key == Int(kVK_Space), !isRepeat, matchesComposerShortcut(flags: flags) {
                cancelTalkForKeyChord()
                DispatchQueue.main.async { self.onComposer?() }
                return Unmanaged.passUnretained(event)
            }

            if key == Int(kVK_Escape) {
                if hasHeldTalkInput { cancelTalkForKeyChord() }
                else { DispatchQueue.main.async { self.onEscape?() } }
                return Unmanaged.passUnretained(event)
            }

            // A real key during a modifier hold is a keyboard shortcut, not speech input.
            if hasHeldTalkInput {
                cancelTalkForKeyChord()
                return Unmanaged.passUnretained(event)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private var delayedModifier: (keyCode: Int, flag: CGEventFlags)? {
        switch talkKey {
        case "rightCommand": return (Int(kVK_RightCommand), .maskCommand)
        case "rightOption": return (Int(kVK_RightOption), .maskAlternate)
        case "rightControl": return (Int(kVK_RightControl), .maskControl)
        default: return nil
        }
    }

    /// Command/Option/Control are also normal shortcut modifiers, so only arm them as talk keys
    /// after a short solitary hold. A normal chord cancels the pending arm without touching the UI.
    private func handleDelayedModifierChange(keyCode: Int, flags: CGEventFlags) {
        guard let delayedModifier, keyCode == delayedModifier.keyCode else { return }
        let isDown = flags.contains(delayedModifier.flag)
        if isDown, !delayedModifierDown {
            delayedModifierDown = true
            delayedModifierArmed = false
            delayedModifierSuppressed = false
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.delayedModifierDown, !self.delayedModifierSuppressed else { return }
                self.delayedModifierArmed = true
                self.beginTalk(from: .delayedModifier)
            }
            delayedModifierTimer = work
            // Short enough that the notch feels immediate; a chord key arriving later still cancels.
            // Half a second of a lone modifier: long enough that ⌘C, ⌘-click, or a rested thumb never
            // opens the microphone, short enough to feel immediate when you mean it.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delayedModifierArmDelay, execute: work)
        } else if !isDown, delayedModifierDown {
            delayedModifierDown = false
            delayedModifierTimer?.cancel()
            delayedModifierTimer = nil
            if delayedModifierArmed, activeTalkSource == .delayedModifier { finishTalk(from: .delayedModifier) }
            delayedModifierArmed = false
            delayedModifierSuppressed = false
        }
    }

    private func handleInstantModifierChange(flags: CGEventFlags) {
        let fn = flags.contains(.maskSecondaryFn)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)
        let command = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let controlOptionDown = control && option
        let primaryDown = talkKey == "fn" ? fn : (talkKey == "controlOption" ? controlOptionDown : false)
        let aliasDown = talkKey == "controlOption" ? false : controlOptionDown
        let physicallyDown = primaryDown || aliasDown
        let eligible = physicallyDown && !command && !shift
            && !(fn && (control || option))

        if physicallyDown {
            if !instantModifierDown {
                instantModifierDown = true
                if eligible, !instantModifierSuppressed { beginTalk(from: .instantModifier) }
            } else if !eligible, !instantModifierSuppressed {
                cancelTalkForKeyChord()
            }
        } else if instantModifierDown {
            instantModifierDown = false
            if activeTalkSource == .instantModifier { finishTalk(from: .instantModifier) }
            instantModifierSuppressed = false
        }
    }

    /// Pressing another modifier turns Right Command/Option/Control into a keyboard chord immediately.
    /// Keep it suppressed until the configured modifier itself is released.
    private func cancelDelayedTalkForAdditionalModifier(keyCode: Int, flags: CGEventFlags) {
        guard delayedModifierDown, let delayedModifier, keyCode != delayedModifier.keyCode,
              let changedFlag = modifierFlag(for: keyCode), flags.contains(changedFlag) else { return }
        cancelTalkForKeyChord()
    }

    private func modifierFlag(for keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case Int(kVK_Command), Int(kVK_RightCommand): return .maskCommand
        case Int(kVK_Option), Int(kVK_RightOption): return .maskAlternate
        case Int(kVK_Control), Int(kVK_RightControl): return .maskControl
        case Int(kVK_Shift), Int(kVK_RightShift): return .maskShift
        case Int(kVK_Function): return .maskSecondaryFn
        default: return nil
        }
    }

    private var hasHeldTalkInput: Bool {
        activeTalkSource != nil || instantModifierDown || delayedModifierDown || functionKeyDown
    }

    private func beginTalk(from source: TalkSource) {
        guard activeTalkSource == nil else { return }
        activeTalkSource = source
        pressStart = Date()
        DispatchQueue.main.async { self.onPress?() }
    }

    private func finishTalk(from source: TalkSource) {
        guard activeTalkSource == source else { return }
        activeTalkSource = nil
        let held = Date().timeIntervalSince(pressStart ?? Date())
        pressStart = nil
        DispatchQueue.main.async { self.onRelease?(held) }
    }

    private func cancelTalkForKeyChord() {
        delayedModifierTimer?.cancel()
        delayedModifierTimer = nil
        delayedModifierArmed = false
        if delayedModifierDown { delayedModifierSuppressed = true }
        if instantModifierDown { instantModifierSuppressed = true }
        if functionKeyDown { functionKeySuppressed = true }
        guard activeTalkSource != nil else { return }
        activeTalkSource = nil
        pressStart = nil
        DispatchQueue.main.async { self.onCancel?() }
    }

    private func matchesComposerShortcut(flags: CGEventFlags) -> Bool {
        let command = flags.contains(.maskCommand)
        let option = flags.contains(.maskAlternate)
        let control = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)
        let function = flags.contains(.maskSecondaryFn)
        switch composerShortcut {
        case "optionSpace": return option && !command && !control && !shift
        case "commandShiftSpace": return command && shift && !option && !control
        case "controlSpace": return control && !command && !option && !shift
        case "fnSpace": return function && !command && !option && !control
        default: return false
        }
    }

    private func resetInputState(cancelActiveTalk: Bool) {
        delayedModifierTimer?.cancel()
        delayedModifierTimer = nil
        let wasActive = activeTalkSource != nil
        activeTalkSource = nil
        instantModifierDown = false
        instantModifierSuppressed = false
        delayedModifierDown = false
        delayedModifierArmed = false
        delayedModifierSuppressed = false
        functionKeyDown = false
        functionKeySuppressed = false
        pressStart = nil
        if cancelActiveTalk, wasActive { DispatchQueue.main.async { self.onCancel?() } }
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
    /// Returns whether access is granted. On a fresh install this puts the system dialog up and
    /// returns false; afterwards it returns the stored answer without showing anything.
    @discardableResult static func requestScreen() -> Bool { CGRequestScreenCaptureAccess() }
    static func requestInputMonitoring() { CGRequestListenEventAccess() }
    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    static var fullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: Paths.home.appendingPathComponent("Library/Messages/chat.db").path)
    }
}

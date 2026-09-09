import AppKit
import SwiftUI

/// Borderless, non-activating panel anchored to the physical notch (or top-center on notchless displays).
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called for a click while collapsed. Handled at the window level so first-click and
    /// non-activating-panel quirks cannot swallow it.
    var onCollapsedClick: (() -> Void)?
    var isCollapsed: (() -> Bool)?

    /// Time of the last mouse-down this panel itself received; the global outside-click check ignores clicks that landed here.
    private(set) var lastInsideMouseDown: Date = .distantPast

    /// Screen rect that counts as "the notch" while collapsed (set by the controller).
    var collapsedHitRect: (() -> NSRect)?
    private var downInsideCollapsed = false
    /// Screen rect of the open glass (plus a little slack). The panel is always canvas-wide, so a
    /// click in the transparent margins beside the glass lands here and counts as "outside".
    var expandedHitRect: (() -> NSRect?)?
    var onOutsideClick: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            lastInsideMouseDown = Date()
            let p = convertPoint(toScreen: event.locationInWindow)
            if isCollapsed?() == false, let glass = expandedHitRect?(), !glass.contains(p) {
                onOutsideClick?()
                return
            }
            downInsideCollapsed = (isCollapsed?() == true) && (collapsedHitRect?().contains(p) ?? false)
        }
        if event.type == .leftMouseUp {
            let p = convertPoint(toScreen: event.locationInWindow)
            let inside = collapsedHitRect?().contains(p) ?? false
            if downInsideCollapsed, inside, isCollapsed?() == true {
                downInsideCollapsed = false
                onCollapsedClick?()
                return
            }
            downInsideCollapsed = false
        }
        super.sendEvent(event)
    }
}

extension NSScreen {
    /// Screen containing the menu bar/notch we should anchor to: the built-in display if present, else main.
    static var notchScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    var hasNotch: Bool { safeAreaInsets.top > 0 }
    /// Exact notch rect in screen coordinates (bottom-left origin).
    var notchRect: NSRect {
        if let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea, hasNotch {
            let w = frame.width - l.width - r.width
            return NSRect(x: frame.midX - w / 2, y: frame.maxY - safeAreaInsets.top, width: w, height: safeAreaInsets.top)
        }
        let h = frame.maxY - visibleFrame.maxY
        return NSRect(x: frame.midX - 100, y: frame.maxY - h, width: 200, height: h)
    }
}

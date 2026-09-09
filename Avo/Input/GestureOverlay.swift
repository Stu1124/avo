import AppKit
import SwiftUI

/// While fn is held, a transparent full-screen overlay draws a blue trail under the cursor.
/// On release, if the user drew anything, a screenshot with the trail burned in is saved and attached.
@MainActor
final class GestureOverlay {
    static let shared = GestureOverlay()
    private var window: NSWindow?
    private var view: TrailView?
    private var timer: Timer?
    private var moved = false
    private var lastPoint: NSPoint?
    private var travel: CGFloat = 0

    private var active = false
    /// Identifies the listen that owns the overlay. A late release from an older listen must not
    /// tear down a newer overlay when the talk key is pressed repeatedly.
    private var generation = 0

    /// Creates the overlay window once and keeps it ordered (alpha 0). Ordering a fresh window on every hold
    /// crashed inside AppKit's ViewBridge (NSRemoteView containingWindowWillOrderOnScreen).
    private func ensureWindow() -> (NSWindow, TrailView) {
        if let w = window, let v = view { return (w, v) }
        let screen = NSScreen.notchScreen
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.level = .screenSaver; w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        let v = TrailView(frame: NSRect(origin: .zero, size: screen.frame.size))
        w.contentView = v
        w.orderFrontRegardless()
        window = w; view = v
        return (w, v)
    }

    /// Builds the transparent trail window outside the first hotkey press.
    func prepare() { _ = ensureWindow() }

    @discardableResult
    func begin() -> Int {
        generation &+= 1
        active = true
        timer?.invalidate()
        let (w, v) = ensureWindow()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.notchScreen
        if w.frame != screen.frame { w.setFrame(screen.frame, display: false); v.frame = NSRect(origin: .zero, size: screen.frame.size) }
        v.clear()
        w.alphaValue = 1
        moved = false; travel = 0; lastPoint = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1/90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return generation
    }

    private func tick() {
        guard let v = view, let w = window else { return }
        let p = NSEvent.mouseLocation
        let local = NSPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY)
        if let last = lastPoint {
            travel += hypot(local.x - last.x, local.y - last.y)
            // A real circle or underline, not the mouse drifting while the key is held.
            if travel > 140 { moved = true }
        }
        lastPoint = local
        if moved { v.add(local) }
        if !v.points.isEmpty { v.needsDisplay = true }   // keeps the tail fading even while the cursor rests
    }

    /// Ends the gesture. Returns saved screenshot paths (with marks) or [] if no gesture.
    /// Async on purpose: the previous version blocked the main thread on a semaphore while waiting for a
    /// Task that itself needed the main actor, so it always deadlocked until the 1.5 s timeout and returned [].
    func end(generation expectedGeneration: Int) async -> [String] {
        guard active, expectedGeneration == generation else { return [] }
        guard Settings.shared.screenAwareness else { discardCurrent(); return [] }
        let points = view?.points ?? []
        let frameWidth = window?.frame.width
        let displayID = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let didMove = moved
        discardCurrent()
        guard didMove, points.count > 20, let frameWidth, frameWidth > 0 else { return [] }
        // Capture with the overlay hidden (Avo's own windows are excluded anyway), then composite the trail on top.
        guard let base = await ScreenCapture.shared.captureMain(maxWidth: 1600, excludingSelf: true, displayID: displayID),
              let img = NSImage(contentsOfFile: base) else { return [] }
        let scale = img.size.width / frameWidth
        let composed = NSImage(size: img.size)
        composed.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: img.size))
        let path = NSBezierPath()
        path.lineWidth = 6 * scale; path.lineCapStyle = .round; path.lineJoinStyle = .round
        for (i, p) in points.enumerated() {
            let q = NSPoint(x: p.x * scale, y: p.y * scale)
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        NSColor(red: 0.22, green: 0.56, blue: 1, alpha: 0.9).setStroke(); path.stroke()
        // numbered badge near the gesture start
        if let first = points.first {
            let b = NSRect(x: first.x * scale - 14, y: first.y * scale + 10, width: 28, height: 28)
            NSColor(red: 0.22, green: 0.56, blue: 1, alpha: 1).setFill(); NSBezierPath(ovalIn: b).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: "1", attributes: attrs)
            s.draw(at: NSPoint(x: b.midX - s.size().width / 2, y: b.midY - s.size().height / 2))
        }
        composed.unlockFocus()
        if let tiff = composed.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage,
           let saved = ScreenCapture.shared.save(cg, name: "gesture-screenshot-1") { return [saved] }
        return []
    }

    /// Tears the overlay down without capturing (cancel / no gesture).
    func discard(generation expectedGeneration: Int? = nil) {
        if let expectedGeneration, expectedGeneration != generation { return }
        generation &+= 1
        discardCurrent()
    }

    private func discardCurrent() {
        timer?.invalidate(); timer = nil
        window?.alphaValue = 0; view?.clear(); active = false
        moved = false; lastPoint = nil; travel = 0
    }
}

/// The live trail fades from its tail like a laser pointer: each segment holds for a moment, then dims out.
/// `points` keeps every point regardless, so the screenshot gets the whole stroke burned in.
final class TrailView: NSView {
    private(set) var points: [NSPoint] = []
    private var stamps: [TimeInterval] = []
    private let hold: TimeInterval = 0.7
    private let fade: TimeInterval = 0.6

    func clear() { points = []; stamps = []; needsDisplay = true }
    func add(_ p: NSPoint) { points.append(p); stamps.append(CACurrentMediaTime()); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let now = CACurrentMediaTime()
        let blue = NSColor(red: 0.22, green: 0.56, blue: 1, alpha: 1)
        // Consecutive segments with the same opacity bucket share one path so the stroke stays smooth.
        var i = 1
        while i < points.count {
            let a = alpha(at: i, now: now)
            let path = NSBezierPath(); path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: points[i - 1])
            var j = i
            while j < points.count, abs(alpha(at: j, now: now) - a) < 0.04 { path.line(to: points[j]); j += 1 }
            if a > 0.01 {
                blue.withAlphaComponent(0.25 * a).setStroke(); path.lineWidth = 14; path.stroke()
                blue.withAlphaComponent(0.95 * a).setStroke(); path.lineWidth = 5; path.stroke()
            }
            i = max(j, i + 1)
        }
    }

    private func alpha(at i: Int, now: TimeInterval) -> CGFloat {
        let age = now - stamps[i]
        if age < hold { return 1 }
        return CGFloat(max(0, 1 - (age - hold) / fade))
    }
}

import AppKit
import SwiftUI

/// A temporary, click-through overlay. Pixels are captured before this window appears.
@MainActor
final class ScreenCaptureFlight {
    static let shared = ScreenCaptureFlight()
    private var window: NSWindow?
    private var cleanup: Task<Void, Never>?
    private var owner = UUID()

    func cancel() {
        owner = UUID()
        cleanup?.cancel()
        cleanup = nil
        window?.orderOut(nil)
        window?.contentView = nil
    }

    /// `to`: screen-space point to land on (the Screen chip when the notch shows one); defaults to the notch.
    func present(path: String, from screenFrame: CGRect, to target: CGPoint? = nil) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        cancel()
        let id = owner
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull else { return }
        let source = screenFrame.isEmpty ? NSScreen.notchScreen.frame : screenFrame
        let sourceRect = CGRect(x: source.minX - union.minX, y: union.maxY - source.maxY, width: source.width, height: source.height)
        let notch = NSScreen.notchScreen.notchRect
        let land = target ?? CGPoint(x: notch.midX, y: notch.midY)
        let destination = CGPoint(x: land.x - union.minX, y: union.maxY - land.y)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let view = CaptureFlightView(image: image, source: sourceRect, destination: destination, reducedMotion: reduceMotion)
        let overlay: NSWindow
        if let window { overlay = window }
        else {
            overlay = NSWindow(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.ignoresMouseEvents = true
            overlay.level = .screenSaver
            overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            overlay.isReleasedWhenClosed = false
            window = overlay
        }
        overlay.setFrame(union, display: false)
        overlay.contentView = NSHostingView(rootView: view)
        overlay.orderFrontRegardless()
        cleanup = Task {
            try? await Task.sleep(nanoseconds: reduceMotion ? 350_000_000 : 1_100_000_000)
            guard !Task.isCancelled, owner == id else { return }
            overlay.orderOut(nil)
            overlay.contentView = nil
            cleanup = nil
        }
    }
}

private struct CaptureFlightView: View {
    let image: NSImage
    let source: CGRect
    let destination: CGPoint
    let reducedMotion: Bool
    private let began = Date()
    private let tint = Color(red: 0.38, green: 0.79, blue: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tick in
            let time = max(0, tick.date.timeIntervalSince(began))
            let shrink = smooth((time - 0.06) / 0.28)
            let fly = smooth((time - 0.24) / 0.68)
            let thumbWidth = min(240.0, source.width * 0.3)
            let width = mix(source.width, thumbWidth, shrink) * (1 - fly * 0.92)
            let height = width * source.height / max(source.width, 1)
            let center = point(fly)
            ZStack(alignment: .topLeading) {
                // A quiet blue exposure frame gives capture a physical boundary without a white flash.
                CaptureCorners().stroke(tint.opacity(max(0, 1 - time / 0.26)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: source.width - 18, height: source.height - 18)
                    .position(x: source.midX, y: source.midY)
                if reducedMotion {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(tint)
                        .position(x: destination.x, y: destination.y + 38)
                        .opacity(max(0, 1 - time / 0.32))
                } else {
                    ForEach(0..<3, id: \.self) { index in
                        let lag = max(0, fly - Double(index + 1) * 0.035)
                        let position = point(lag)
                        Circle().fill(tint.opacity(0.2 * fly * (1 - fly)))
                            .frame(width: 6 - CGFloat(index), height: 6 - CGFloat(index))
                            .position(position)
                    }
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: max(2, width), height: max(2, height))
                        .clipShape(RoundedRectangle(cornerRadius: 14 * shrink * (1 - fly)))
                        .overlay(RoundedRectangle(cornerRadius: 14 * shrink * (1 - fly)).strokeBorder(tint.opacity(0.8 * shrink), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4 * shrink), radius: 18 * shrink, y: 8 * shrink)
                        .rotationEffect(.degrees(-5 * sin(fly * .pi)))
                        .position(center)
                        .opacity(time > 0.87 ? max(0, (1.02 - time) / 0.15) : 1)
                    Ellipse().stroke(tint.opacity(max(0, 1 - abs(time - 0.92) / 0.13)), lineWidth: 1.5)
                        .frame(width: 44 + 36 * smooth((time - 0.88) / 0.15), height: 12)
                        .position(x: destination.x, y: destination.y + 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
    private func mix(_ from: Double, _ to: Double, _ t: Double) -> Double { from + (to - from) * t }
    private func point(_ t: Double) -> CGPoint {
        let p = CGPoint(x: source.midX, y: source.midY)
        let a = CGPoint(x: p.x + 90, y: p.y - 45)
        let b = CGPoint(x: destination.x + 85, y: destination.y + 130)
        let u = 1 - t
        return CGPoint(x: u*u*u*p.x + 3*u*u*t*a.x + 3*u*t*t*b.x + t*t*t*destination.x,
                       y: u*u*u*p.y + 3*u*u*t*a.y + 3*u*t*t*b.y + t*t*t*destination.y)
    }
}

private struct CaptureCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length: CGFloat = 38
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            path.move(to: CGPoint(x: x, y: y + dy * length))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * length, y: y))
        }
        return path
    }
}

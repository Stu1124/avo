import SwiftUI

/// Root SwiftUI view inside the notch panel. The controller keeps the panel fitted to this surface.
struct NotchRoot: View {
    @ObservedObject var model: NotchModel
    let controller: NotchController

    var body: some View {
        VStack(spacing: 0) {
            NotchSurface(model: model, controller: controller)
                .frame(maxWidth: .infinity, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { h in
            if model.hoverPinned != h { model.hoverPinned = h }
        }
    }
}

/// The glass surface that hangs from the notch.
struct NotchSurface: View {
    @ObservedObject var model: NotchModel
    let controller: NotchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var notchWidth: CGFloat { NSScreen.notchScreen.notchRect.width }
    private var notchHeight: CGFloat { max(30, NSScreen.notchScreen.notchRect.height) }

    var body: some View {
        let expanded = model.expanded
        let compact = model.isCompactComposer
        let listening = model.phase == .listening
        // Pointer over the collapsed notch. Listening, thinking and replying own the notch already,
        // so the hover reaction stays out of their way.
        let busy = model.phase == .listening || model.phase == .thinking || model.phase == .responding
        let hover = !expanded && !busy && model.collapsedHover
        // Reduce Motion keeps the glow — it is the part that says "clickable" — and drops the growth.
        let lift: CGFloat = hover && !reduceMotion ? 1 : 0
        let collapsedHeight = notchHeight + lift * 4
        // Listening should read as a subtle extension of the hardware, not an opened window.
        let listeningWidth = max(notchWidth + 44, 320)
        let width: CGFloat = expanded ? (listening ? listeningWidth : (compact ? 360 : NotchController.expandedWidth)) : notchWidth + lift * 12
        ZStack(alignment: .top) {
            NotchShape(topRadius: expanded ? 14 : 8, bottomRadius: expanded ? Theme.radiusNotch : 12)
                .fill(Color.black)
                .shadow(color: hover ? Theme.accent.opacity(0.26) : .clear, radius: 8, x: 0, y: 2)
                .overlay(
                    NotchShape(topRadius: expanded ? 14 : 8, bottomRadius: expanded ? Theme.radiusNotch : 12)
                        .fill(LinearGradient(colors: [Color.white.opacity(expanded ? 0.06 : 0), .clear], startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    NotchShape(topRadius: expanded ? 14 : 8, bottomRadius: expanded ? Theme.radiusNotch : 12)
                        .stroke(Color.white.opacity(expanded ? 0.10 : 0), lineWidth: 0.8)
                )

            if expanded, listening {
                CompactListeningView(model: model)
                    .padding(.top, notchHeight + 4)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 7)
            } else if expanded, compact {
                ComposerView(model: model, controller: controller)
                    .padding(.top, notchHeight + 6)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            } else if expanded {
                NotchContent(model: model, controller: controller)
                    .padding(.top, notchHeight + 6)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            } else {
                // Collapsed: the panel ignores mouse events (global monitors catch the notch click and
                // the pointer moving over it), so the shape is the bare notch plus the hover reaction.
                CollapsedIndicator(model: model)
                    .frame(width: width, height: collapsedHeight)
            }
        }
        .frame(width: width, height: expanded ? nil : collapsedHeight, alignment: .top)
        // Quick springs: open/close and the listening→full width change animate inside the controller's
        // fixed canvas, so the window never has to chase the glass mid-animation.
        .animation(expanded ? Theme.springOpen : Theme.springClose, value: expanded)
        .animation(Theme.springQuick, value: listening)
        .animation(Theme.springQuick, value: compact)
        // Hangs from the top edge, so the notch grows down and out by a couple of points.
        .animation(reduceMotion ? nil : Theme.springQuick, value: hover)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { f in
            controller.surfaceFrameChanged(f)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fixed-height push-to-talk feedback. Live transcript changes never resize the panel.
struct CompactListeningView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 12) {
            DictationWave(level: model.finalizingSpeech ? 0 : model.audioLevel, finishing: model.finalizingSpeech)
                .frame(width: 58, height: 30)
            Text(model.transcript.isEmpty ? (model.finalizingSpeech ? "Finishing…" : (model.microphoneReady ? "Listening" : "Starting microphone…")) : model.transcript)
                .font(Theme.text(12, .medium))
                .foregroundStyle(model.transcript.isEmpty ? Theme.ink3 : Theme.ink)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 34)
    }
}


/// Little life in the collapsed state: nothing normally; a breathing dot while a side task runs.
/// Hover only grows the notch a couple of points and adds a faint glow; it never opens anything
/// by itself, and it never changes what is clickable.
struct CollapsedIndicator: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var wake = WakeWordState.shared
    @State private var pulse = false
    var body: some View {
        HStack {
            if wake.active {
                Circle().fill(wake.capturing ? Theme.accent : Theme.ink3).frame(width: 4, height: 4).padding(.leading, 10)
                    .opacity(wake.capturing ? 1 : 0.7)
            }
            Spacer()
            if model.sideTasks.contains(where: { $0.state == "running" || $0.needsInput }) {
                Circle()
                    .fill(model.sideTasks.contains(where: { $0.needsInput }) ? Theme.warn : Theme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 1 : 0.35)
                    .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true } }
                    .padding(.trailing, 10)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Notch silhouette: flat top, rounded bottom corners, small concave ears at the top like the real hardware.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX - topRadius, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + topRadius), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: r.minX + bottomRadius, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - bottomRadius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - bottomRadius), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + topRadius))
        p.addQuadCurve(to: CGPoint(x: r.maxX + topRadius, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}


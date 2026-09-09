import SwiftUI

/// The Avo mark, drawn the same way as `design/avo-mark.svg`: a lowercase "a" whose bowl is a
/// single open stroke closed by a full-height stem, followed by three short meter bars that
/// stand on the letter's baseline and stop well below its crown. `size` is the width; the mark
/// is wide and short (668 x 310), so the height follows at 0.46 of it.
///
/// With `animated` on, and Reduce Motion off, the three bars settle and rise again on a slow
/// spring, the way a meter idles between words. Only the bar tops move: the baseline is shared
/// and fixed, the stem belongs to the letter and never moves, and the bars keep their rising
/// order — and stay under the stem — at every frame of the cycle.
struct AvoMark: View {
    var size: CGFloat = 44
    var animated: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breath: CGFloat = 0

    static let aspect: CGFloat = AvoGlyph.visualHeight / AvoGlyph.visualWidth

    var body: some View {
        AvoGlyph(breath: breath)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: AvoGlyph.stroke * size / AvoGlyph.visualWidth,
                                                     lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size * Self.aspect)
            .onAppear(perform: startBreathing)
            .onChange(of: animated) { _, _ in startBreathing() }
            // Reduce Motion can be switched on while a window is open; without this the mark
            // would keep breathing until the view was rebuilt.
            .onChange(of: reduceMotion) { _, _ in startBreathing() }
    }

    private func startBreathing() {
        guard animated, !reduceMotion else {
            // Cancel any repeating animation already in flight, then pin the mark at rest.
            withAnimation(.linear(duration: 0)) { breath = 0 }
            return
        }
        withAnimation(.spring(response: 2.4, dampingFraction: 0.9).repeatForever(autoreverses: true)) {
            breath = 1
        }
    }
}

/// The glyph path on the 1024 grid the SVGs use, mapped into whatever rect it is given.
/// Ink bounds are x 178...846, y 357...667 — the path bounds plus the half stroke the round
/// caps add on every side.
struct AvoGlyph: Shape {
    /// 0 = the resting mark, exactly what the SVGs draw. 1 = the far end of the breath.
    var breath: CGFloat = 0

    static let stroke: CGFloat = 62
    static let visualWidth: CGFloat = 668
    static let visualHeight: CGFloat = 310
    private static let originX: CGFloat = 178
    private static let originY: CGFloat = 357

    // Bowl: r = 124 about (333, 512), drawn from 30 degrees round to 330, so the 60-degree
    // aperture faces due right and the stem covers it.
    private static let bowlCentre = CGPoint(x: 333, y: 512)
    private static let bowlRadius: CGFloat = 124
    private static let arcStart: CGFloat = 30
    private static let arcEnd: CGFloat = 330

    /// x, the shared baseline, then the top at rest and the top at the far end of the breath.
    /// The first entry is the letter's stem: its two tops are identical, so it is stationary.
    /// Bar lengths are 96 / 146 / 191 at rest and 66 / 111 / 151 at the far end — rising in
    /// both states, and always under the stem's 248, so both hold at every point between.
    private static let bars: [(x: CGFloat, bottom: CGFloat, top: CGFloat, topUp: CGFloat)] = [
        (457, 636, 388, 388),
        (579, 636, 540, 570),
        (697, 636, 490, 525),
        (815, 636, 445, 485),
    ]

    var animatableData: CGFloat {
        get { breath }
        set { breath = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let k = rect.width / Self.visualWidth
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - Self.originX) * k, y: rect.minY + (y - Self.originY) * k)
        }

        var path = Path()

        // Sampled rather than addArc: the sign of SwiftUI's `clockwise` flag depends on the
        // coordinate space, and sampling states the direction outright.
        let steps = 72
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let deg = Self.arcStart + (Self.arcEnd - Self.arcStart) * t
            let rad = deg * .pi / 180
            let point = p(Self.bowlCentre.x + Self.bowlRadius * cos(rad),
                          Self.bowlCentre.y - Self.bowlRadius * sin(rad))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        let t = min(max(breath, 0), 1)
        for bar in Self.bars {
            let top = bar.top + (bar.topUp - bar.top) * t
            path.move(to: p(bar.x, top))
            path.addLine(to: p(bar.x, bar.bottom))
        }
        return path
    }
}

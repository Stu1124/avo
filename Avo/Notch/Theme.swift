import SwiftUI

/// Design tokens. Dark glass only.
enum Theme {
    // Text tints, brightest first. Everything down to `ink3` is meant to be read: on Avo's glass
    // (~#0C0C0E) `ink` is 18:1, `ink2` 7:1 and `ink3` 4.9:1, so the smallest supporting line still
    // clears WCAG AA. `ink4` is 1.6:1 and is decoration only — dots, chevrons, disabled fills.
    // Never put a word in it.
    static let ink = Color(white: 0.96)
    static let ink2 = Color(white: 0.96).opacity(0.62)
    static let ink3 = Color(white: 0.96).opacity(0.50)
    static let ink4 = Color(white: 0.96).opacity(0.18)
    static let line = Color.white.opacity(0.08)
    static let lineStrong = Color.white.opacity(0.14)
    static let fill1 = Color.white.opacity(0.06)
    static let fill2 = Color.white.opacity(0.10)
    static let glass = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let accent = Color(red: 0.216, green: 0.561, blue: 1.0)
    static let good = Color(red: 0.204, green: 0.78, blue: 0.349)
    static let bad = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let warn = Color(red: 1.0, green: 0.62, blue: 0.04)

    static let radiusNotch: CGFloat = 26
    static let radiusCard: CGFloat = 18
    static let radiusField: CGFloat = 12
    static let radiusPill: CGFloat = 999

    // Motion: springs only, never ease-in. Tight responses so the notch feels instant.
    static let springOpen = Animation.spring(response: 0.26, dampingFraction: 0.85)
    static let springClose = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let springCard = Animation.spring(response: 0.36, dampingFraction: 0.84)
    static let springQuick = Animation.spring(response: 0.2, dampingFraction: 0.9)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct GlassBackground: View {
    var radius: CGFloat = Theme.radiusCard
    var strength: Double = 1
    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow, blending: .behindWindow)
            Theme.glass.opacity(0.82 * strength)
            LinearGradient(colors: [Color.white.opacity(0.05), .clear, Color.black.opacity(0.12)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
        )
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending; v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

extension View {
    func glassCard(radius: CGFloat = Theme.radiusCard) -> some View {
        background(GlassBackground(radius: radius))
            .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 14)
    }
}

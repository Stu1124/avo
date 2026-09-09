import SwiftUI

/// One voice-driven form: a bank of tapered light bars that settles into a quiet pulse on release.
/// The envelope comes from microphone energy; silence does not pretend that speech was detected.
struct DictationWave: View {
    var level: Float
    var finishing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { tick in
            let time = reduceMotion ? 0 : tick.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let count = 17
                let energy = min(1, max(0, Double(level)))
                let gradient = Gradient(colors: [Color(red: 0.3, green: 0.89, blue: 0.94), Theme.accent, Color(red: 0.66, green: 0.58, blue: 1)])
                for index in 0..<count {
                    let unit = Double(index) / Double(count - 1)
                    let taper = pow(sin(unit * .pi), 0.7)
                    let rhythm = 0.55 + 0.45 * sin(time * 9 + unit * 12) * sin(time * 4 - unit * 7)
                    let pulse = finishing ? (0.12 + 0.1 * sin(time * 5 - unit * 5)) : energy * rhythm
                    let height = 3 + (size.height - 3) * taper * pulse
                    let x = unit * (size.width - 2.5)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: 2.5, height: height)
                    let bar = Path(roundedRect: rect, cornerRadius: 1.25)
                    context.opacity = 0.45 + 0.55 * max(energy, finishing ? 0.5 : 0)
                    context.fill(bar, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                }
            }
        }
        .accessibilityLabel(finishing ? "Finishing dictation" : "Microphone level")
    }
}

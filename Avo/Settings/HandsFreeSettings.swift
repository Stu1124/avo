import SwiftUI

/// Voice page section: wake-word toggle, phrase, and live status. Insert into `VoicePage` below "Voice mode".
/// Wake-word listening needs SpeechAnalyzer (macOS 26); below that the section explains why it is absent.
struct HandsFreeSection: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var state = WakeWordState.shared

    private var status: (DotState, String) {
        if !s.handsFree { return (.off, "Off") }
        if let p = state.problem { return (.bad, p) }
        if state.capturing { return (.ok, "Capturing") }
        if state.active { return (.ok, "Listening for “\(s.wakeWord)”") }
        return (.warn, "Paused")
    }

    var body: some View {
        SectionCard(title: "Hands-free", footer: "Keeps the microphone open and listens on-device for the wake phrase only. Say it, then your request; Avo runs it after a short pause. Pauses automatically during push-to-talk, voice mode, and while Avo speaks.") {
            if #available(macOS 26, *) {
                ToggleRow(title: "Listen for a wake word", subtitle: "On-device. Nothing leaves the Mac until the phrase is heard.", isOn: $s.handsFree)
                TextRow(title: "Wake word", subtitle: "“Hey Avo”, “OK Avo” and “Avo” always work.", placeholder: "Hey Avo", text: $s.wakeWord, width: 200)
                ActionRow(title: "Status") {
                    StatusLabel(state: status.0, text: status.1)
                }
            } else {
                Text("Hands-free needs macOS 26.")
                    .font(DS.font(13, .medium))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
        }
    }
}

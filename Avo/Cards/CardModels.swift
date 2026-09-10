import Foundation

/// Editable confirmation before an acting tool runs. Fields bind to tool arguments.
struct ConfirmationCard: Identifiable {
    enum FieldKind { case text, multiline, datetime, select([String]), toggle }
    /// Which app-shaped body renders the fields. `.generic` is the label/value list.
    enum Layout { case generic, reminder, event, email, reply, message, note }
    struct Field: Identifiable {
        let id: String           // argument key
        var label: String
        var kind: FieldKind
        var value: String
        var required: Bool = false
    }
    let id: UUID
    var icon: String             // SF symbol or app:<bundleId>
    var title: String            // "Send iMessage"
    var subtitle: String?        // "to Kai"
    var fields: [Field]
    var confirmLabel = "Confirm"
    var destructive = false
    var layout: Layout = .generic
    var revision = 0
    var onDecision: ((Decision) -> Void)?
    enum Decision { case confirm([String: String]), cancel }
    func value(_ key: String) -> String { fields.first { $0.id == key }?.value ?? "" }
}

/// Result card blocks: a small at-a-glance vocabulary, trimmed to what reads well.
struct GlanceCard: Identifiable {
    enum Block {
        case header(title: String, subtitle: String?, icon: String)
        case list(rows: [Row])
        case stats(items: [Stat])
        case keyValue(pairs: [(String, String)])
        case bars(items: [(String, Double)])
        case progress(value: Double, max: Double, label: String?)
        case badges([Badge])
        case text(String)
        /// A full email: who, when, the whole body, attachments, and actions.
        case email(from: String, address: String, date: String, body: String, attachments: [String])
        case actions([Action])
    }
    struct Action: Identifiable { let id = UUID(); var label: String; var icon: String?; var accent = false; var run: () -> Void }
    struct Row: Identifiable {
        let id = UUID(); var title: String; var subtitle: String?; var icon: String?; var trailing: String?; var tone: Tone = .neutral; var url: String? = nil; var path: String? = nil
        /// Per-source extras. Unset means the plain row.
        var accent: String? = nil        // hex color: calendar/list color rail or dot
        var avatar: String? = nil        // initials for a person row
        var meta: String? = nil          // third line (snippet)
        var unread = false
        var checkable = false            // reminders: circle checkbox
        var onToggle: (() -> Void)? = nil
        var imageURL: String? = nil      // album art, file thumbnail
    }
    /// Visual family, from `source`.
    enum Style { case gmail, calendar, reminders, notes, messages, files, spotify, coding, plain }
    var style: Style {
        switch source?.lowercased() {
        case "gmail": return .gmail
        case "calendar", "google calendar": return .calendar
        case "reminders": return .reminders
        case "notes": return .notes
        case "messages", "imessage": return .messages
        case "finder", "google drive", "drive": return .files
        case "spotify": return .spotify
        case "coding agents": return .coding
        default: return .plain
        }
    }
    struct Stat: Identifiable { let id = UUID(); var label: String; var value: String; var delta: String?; var tone: Tone = .neutral }
    struct Badge: Identifiable { let id = UUID(); var text: String; var tone: Tone = .neutral }
    enum Tone { case neutral, good, bad, accent }
    let id: UUID
    var blocks: [Block]
    var source: String?          // "Gmail", "Calendar" — shows as a footer chip with icon
    var sourceIcon: String?
    var revision = 0
}

/// Staged text the user can edit and copy (draft reply, prompt, rewritten text).
struct DraftCard: Identifiable {
    let id: UUID
    var title: String
    var text: String
    var hint: String             // "Copied. Paste with ⌘V"
    var revision = 0
    var onChange: ((String) -> Void)?
}

struct FilesCard: Identifiable {
    struct File: Identifiable { let id = UUID(); var name: String; var path: String; var kind: String; var modified: Date?; var size: Int64? }
    let id: UUID
    var title: String
    var files: [File]
    var revision = 0
}

/// A running coding agent (Claude Code / Codex) or other long task.
struct TaskCard: Identifiable {
    let id: UUID
    var taskId: String
    var agent: String            // "Claude Code" / "Codex"
    var title: String
    var status: String           // running, waiting, done, failed
    var lines: [String]          // recent activity lines
    var result: String?
    var project: String? = nil   // "~/Documents/Projects"
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var agentKey: String = "claude"  // "claude" | "codex"
    var model: String? = nil
    var effort: String? = nil
    var revision = 0
    var onAction: ((String) -> Void)?   // "stop", "open", "reply:<text>"
}

struct ReminderCard: Identifiable {
    let id: UUID
    var reminderId: String
    var message: String
    var url: String?
    var fireAt: Date
    var revision = 0
    var onAction: ((String) -> Void)?   // "done", "snooze:15", "open"
}

/// Agent asks the user something (or Claude Code permission prompt).
struct QuestionCard: Identifiable {
    let id: UUID
    var icon: String
    var title: String
    var body: String
    var options: [String]
    var allowFreeText: Bool
    var revision = 0
    var onAnswer: ((String) -> Void)?
}

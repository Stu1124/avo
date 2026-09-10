import Foundation

/// Apple Notes through its AppleScript dictionary. Note ids are Notes' own `id` (x-coredata URLs).
/// Reads use the note's `plaintext` property (Notes strips its own HTML); writes convert plain text to Notes HTML.
enum NotesApp {
    static let icon = "app:com.apple.Notes"
    static let group = "Notes"
    private static let us = "\u{1F}"   // unit separator between fields
    private static let rs = "\u{1E}"   // record separator between rows
    static let hidden: Set<String> = ["Recently Deleted"]

    struct Note {
        var id: String; var title: String; var folder: String; var modified: Date?
        var json: [String: Any] {
            var j: [String: Any] = ["note_id": id, "title": title, "folder": folder]
            if let m = modified { j["modified"] = HDate.human(m); j["modified_iso"] = HDate.iso(m) }
            return j
        }
        var row: GlanceCard.Row {
            GlanceCard.Row(title: title.isEmpty ? "Untitled" : title, subtitle: folder.isEmpty ? nil : folder, icon: "note.text", trailing: modified.map(HDate.relative))
        }
    }

    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }

    /// Wrap a body in `tell application "Notes"` with the separators and a date formatter handler available as `my fmt(d)`.
    static func run(_ body: String, timeout: TimeInterval = 20) async throws -> String {
        let script = """
        on pad(n)
            if n < 10 then return "0" & n
            return n as text
        end pad
        on fmt(d)
            return ((year of d) as text) & "-" & my pad((month of d) as integer) & "-" & my pad(day of d) & " " & my pad(hours of d) & ":" & my pad(minutes of d)
        end fmt
        tell application "Notes"
            set us to character id 31
            set rs to character id 30
        \(body)
        end tell
        """
        return try await AppleScript.run(script, timeout: timeout)
    }

    static func rows(_ out: String) -> [[String]] {
        out.components(separatedBy: rs).map { $0.components(separatedBy: us) }.filter { $0.count > 1 || !($0.first ?? "").isEmpty }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    static func date(_ s: String) -> Date? { dateFormatter.date(from: s.trimmingCharacters(in: .whitespaces)) }

    static func q(_ s: String) -> String { AppleScript.quote(s) }

    // MARK: folders

    static func folders() async throws -> [(name: String, count: Int)] {
        let out = try await run("""
            set out to ""
            repeat with f in folders
                set out to out & (name of f) & us & (count of notes of f) & rs
            end repeat
            return out
        """)
        return rows(out).compactMap { r in r.count >= 2 ? (name: r[0], count: Int(r[1]) ?? 0) : nil }.filter { !hidden.contains($0.name) }
    }

    /// Exact, then case-insensitive, then substring match on folder names. Throws with the real names when nothing matches.
    static func resolveFolder(_ name: String?) async throws -> String? {
        guard let name, !name.isEmpty else { return nil }
        let all = try await folders().map(\.name)
        if let f = all.first(where: { $0 == name }) { return f }
        if let f = all.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return f }
        if let f = all.first(where: { $0.range(of: name, options: .caseInsensitive) != nil }) { return f }
        throw Failure(message: "No Notes folder named '\(name)'. Folders: \(all.joined(separator: ", ")).")
    }

    // MARK: notes

    /// Title, id, modified, folder for every note (optionally one folder). No bodies.
    static func list(folder: String?) async throws -> [Note] {
        let scope = folder.map { "{folder \(q($0))}" } ?? "folders"
        let out = try await run("""
            set out to ""
            repeat with f in \(scope)
                set fn to name of f
                if fn is not "Recently Deleted" then
                    set nm to name of every note of f
                    set ids to id of every note of f
                    set md to modification date of every note of f
                    repeat with i from 1 to count of nm
                        set out to out & (item i of nm) & us & (item i of ids) & us & (my fmt(item i of md)) & us & fn & rs
                    end repeat
                end if
            end repeat
            return out
        """, timeout: 40)
        return rows(out).compactMap { r in r.count >= 4 ? Note(id: r[1], title: r[0], folder: r[3], modified: date(r[2])) : nil }
    }

    static func search(_ query: String, limit: Int) async throws -> [Note] {
        let out = try await run("""
            set out to ""
            set hits to (every note whose (name contains \(q(query))) or (plaintext contains \(q(query))))
            set n to 0
            repeat with h in hits
                set n to n + 1
                if n > \(limit) then exit repeat
                set fn to ""
                try
                    set fn to name of (item 1 of (every folder whose notes contains h))
                end try
                if fn is not "Recently Deleted" then
                    set out to out & (name of h) & us & (id of h) & us & (my fmt(modification date of h)) & us & fn & rs
                end if
            end repeat
            return out
        """, timeout: 40)
        return rows(out).compactMap { r in r.count >= 4 ? Note(id: r[1], title: r[0], folder: r[3], modified: date(r[2])) : nil }
    }

    /// Resolve a note reference expression: by id, else by unambiguous title (optionally inside a folder).
    static func reference(id: String?, title: String?, folder: String?) async throws -> (expr: String, note: Note) {
        if let id, !id.isEmpty {
            let out = try await run("""
                set n to note id \(q(id))
                set fn to ""
                try
                    set fn to name of (item 1 of (every folder whose notes contains n))
                end try
                return (name of n) & us & (id of n) & us & (my fmt(modification date of n)) & us & fn
            """)
            let r = rows(out).first ?? []
            guard r.count >= 4 else { throw Failure(message: "No note with id \(id).") }
            return ("note id \(q(id))", Note(id: r[1], title: r[0], folder: r[3], modified: date(r[2])))
        }
        guard let title, !title.isEmpty else { throw Failure(message: "Pass note_id or the note's title.") }
        let f = try await resolveFolder(folder)
        let all = try await list(folder: f)
        var hits = all.filter { $0.title == title }
        if hits.isEmpty { hits = all.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame } }
        if hits.isEmpty { hits = all.filter { $0.title.range(of: title, options: .caseInsensitive) != nil } }
        guard !hits.isEmpty else { throw Failure(message: "No note titled '\(title)'\(f.map { " in \($0)" } ?? "").") }
        guard hits.count == 1 else {
            throw Failure(message: "Several notes match '\(title)': \(hits.prefix(5).map { "\($0.title) (\($0.folder), \($0.id))" }.joined(separator: "; ")). Pass the exact note_id.")
        }
        return ("note id \(q(hits[0].id))", hits[0])
    }

    static func plaintext(expr: String) async throws -> String {
        try await run("return plaintext of (\(expr))", timeout: 30)
    }

    static func create(title: String, folder: String?, body: String?) async throws -> String {
        let at = folder.map { " at folder \(q($0))" } ?? ""
        let html = body.map(htmlFromText) ?? ""
        return try await run("""
            set n to make new note\(at) with properties {name:\(q(title)), body:\(q(html))}
            return id of n
        """)
    }

    static func append(expr: String, text: String) async throws {
        _ = try await run("""
            set n to \(expr)
            set body of n to (body of n) & \(q(htmlFromText(text)))
            return "ok"
        """)
    }

    // MARK: text ⇄ HTML

    static func htmlFromText(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return "<div><br></div>" }
            let esc = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return "<div>\(esc)</div>"
        }.joined(separator: "\n")
    }

    /// Notes' plaintext starts with the title line; drop it so the body is just the body.
    static func body(fromPlaintext p: String, title: String) -> String {
        var lines = p.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fail(_ e: Error) -> ToolResult {
        let m = "\(e)"
        if m.contains("-1743") || m.localizedCaseInsensitiveContains("not allowed") {
            return .fail("Notes automation is not allowed.", guidance: "Tell the user to enable Avo → Notes under System Settings → Privacy & Security → Automation.")
        }
        return .fail(m)
    }
}

enum NotesTools {
    static let group = NotesApp.group
    static let icon = NotesApp.icon

    static func all() -> [Tool] { [ListFolders(), ListNotes(), SearchNotes(), GetNote(), CreateNote(), AppendToNote()] }

    static let noteIdParam = ToolParam("note_id", "string", "A note_id exactly as list_notes or search_notes returned it. Addressing a note this way is unambiguous, and it is the route to prefer.")
    static let noteTitleParam = ToolParam("note", "string", "A note's title, consulted only where no note_id was given, and it has to single out one existing note without ambiguity. Where you know it, pass it together with note_id so the confirmation card has a name to display.")
    static let folderParam = ToolParam("folder", "string", "Optional folder name to narrow a title lookup (from list_note_folders).")

    struct ListFolders: Tool {
        let name = "list_note_folders"
        let description = "Enumerates the folders inside Notes — 'Notes', 'Work', 'Recipes' and whatever else the user keeps — along with how many notes each holds. Run it before listing or creating anything, so you know what folders are actually there."
        let params: [ToolParam] = []
        let statusLabel = "Reading folders"
        let statusIcon = NotesTools.icon
        let group = NotesTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            do {
                let fs = try await NotesApp.folders()
                Log.info("Notes folders → \(fs.count)")
                let rows = fs.prefix(6).map { GlanceCard.Row(title: $0.name, icon: "folder", trailing: "\($0.count)") }
                return .ok(["ok": true, "folders": fs.map { ["name": $0.name, "notes": $0.count] }],
                           cards: [Cards.glance(source: "Notes", icon: NotesTools.icon, rows: rows)])
            } catch { return NotesApp.fail(error) }
        }
    }

    struct ListNotes: Tool {
        let name = "list_notes"
        let description = "Returns notes, either across the board or confined to one folder. Every entry gives the folder it lives in, its title, when it last changed, and the note_id that reading or appending requires. Bodies are NOT included here, to keep it fast, so pass a note_id to get_note when the contents are wanted. This covers 'what notes do I have?' and 'show my notes in Work'."
        let params = [
            ToolParam("folder", "string", "One folder's name, as list_note_folders reports it. Leaving it out spans every folder instead."),
            ToolParam("limit", "integer", "Maximum number of notes to return, newest first (default 30)."),
        ]
        let statusLabel = "Reading notes"
        let statusIcon = NotesTools.icon
        let group = NotesTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            do {
                let folder = try await NotesApp.resolveFolder(args.str("folder"))
                var notes = try await NotesApp.list(folder: folder)
                notes.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                let limit = max(args.int("limit") ?? 30, 1)
                let shown = Array(notes.prefix(limit))
                Log.info("Notes list \(folder ?? "all") → \(notes.count)")
                let header = (folder ?? "Notes", "\(notes.count) note\(notes.count == 1 ? "" : "s")")
                let card = shown.isEmpty
                    ? Cards.note(source: "Notes", icon: NotesTools.icon, title: header.0, body: "No notes here.")
                    : Cards.glance(source: "Notes", icon: NotesTools.icon, header: header, rows: shown.prefix(6).map(\.row))
                return .ok(["ok": true, "count": notes.count, "notes": shown.map(\.json)], cards: [card])
            } catch { return NotesApp.fail(error) }
        }
    }

    struct SearchNotes: Tool {
        let name = "search_notes"
        let description = "Hunts through every folder for a phrase, checking both titles and body text. Matches come back with their folder, title and note_id; feed that id to get_note to see the whole thing. It handles requests like 'find my note about the trip' and 'which note has the wifi password?'."
        let params = [
            ToolParam("query", "string", "Words to look for in note titles and bodies.", required: true),
            ToolParam("limit", "integer", "Maximum number of matches to return (default 20)."),
        ]
        let statusLabel = "Searching notes"
        let statusIcon = NotesTools.icon
        let group = NotesTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let query = args.str("query") else { return .fail("query is required") }
            do {
                var hits = try await NotesApp.search(query, limit: max(args.int("limit") ?? 20, 1))
                hits.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                Log.info("Notes search '\(query)' → \(hits.count)")
                let card = hits.isEmpty ? [] : [Cards.glance(source: "Notes", icon: NotesTools.icon, header: ("\"\(query)\"", "\(hits.count) match\(hits.count == 1 ? "" : "es")"), rows: hits.prefix(6).map(\.row))]
                return .ok(["ok": true, "count": hits.count, "notes": hits.map(\.json)], cards: card)
            } catch { return NotesApp.fail(error) }
        }
    }

    struct GetNote: Tool {
        let name = "get_note"
        let description = "Returns one note's complete text, unformatted. The dependable way in is the note_id from list_notes or search_notes; a title works too, optionally narrowed by folder, but a title that fits more than one note produces a refusal instead of a guess. Behind 'read me my grocery note' and 'what's in my packing list?'."
        let params = [NotesTools.noteIdParam, NotesTools.noteTitleParam, NotesTools.folderParam]
        let statusLabel = "Reading note"
        let statusIcon = NotesTools.icon
        let group = NotesTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            do {
                let (expr, note) = try await NotesApp.reference(id: args.str("note_id"), title: args.str("note"), folder: args.str("folder"))
                let text = NotesApp.body(fromPlaintext: try await NotesApp.plaintext(expr: expr), title: note.title)
                Log.info("Notes get '\(note.title)' → \(text.count) chars")
                var j = note.json
                j["ok"] = true
                j["body"] = String(text.prefix(12_000))
                if text.count > 12_000 { j["truncated"] = true }
                let card = Cards.note(source: "Notes", icon: NotesTools.icon, title: note.title.isEmpty ? "Untitled" : note.title, body: text.isEmpty ? "(empty)" : text.preview(280))
                return .ok(j, cards: [card])
            } catch { return NotesApp.fail(error) }
        }
    }

    struct CreateNote: Tool {
        let name = "create_note"
        let description = "Makes a note that does not exist yet. A title is required; a folder taken from list_note_folders and some body text are both optional, and with no folder the default one receives it. Use it for 'jot down these meeting notes' or 'make a note titled Packing List'."
        let params = [
            ToolParam("title", "string", "The note's title (its first line).", required: true),
            ToolParam("folder", "string", "Which folder receives the note, named as list_note_folders reports it. With nothing given, Notes' default folder takes it."),
            ToolParam("body", "string", "Optional. The note's contents, as plain text — newlines survive intact."),
        ]
        let statusLabel = "Creating note"
        let statusIcon = NotesTools.icon
        let group = NotesTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: NotesTools.icon, title: "Create note", subtitle: { $0.str("title") },
                             fields: [(key: "title", label: "Title", kind: .text, required: true),
                                      (key: "folder", label: "Folder", kind: .text, required: false),
                                      (key: "body", label: "Body", kind: .multiline, required: false)],
                             confirmLabel: "Create", layout: .note)
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let title = args.str("title") else { return .fail("title is required") }
            do {
                let folder = try await NotesApp.resolveFolder(args.str("folder"))
                let id = try await NotesApp.create(title: title, folder: folder, body: args["body"] as? String)
                Log.info("Notes create '\(title)' → \(id)")
                let card = Cards.note(source: "Notes", icon: NotesTools.icon, title: title, body: (args.str("body") ?? "").isEmpty ? "Created\(folder.map { " in \($0)" } ?? "")." : args.str("body")!.preview(160))
                return .ok(["ok": true, "note_id": id, "title": title, "folder": folder ?? "default"], cards: [card], narration: "Created the note \(title).")
            } catch { return NotesApp.fail(error) }
        }
    }

    struct AppendToNote: Tool {
        let name = "append_to_note"
        let description = "Adds text onto the bottom of a note that already exists. The dependable way in is the note_id from list_notes or search_notes; a title works too, optionally narrowed by folder, but a title matching several notes produces a refusal rather than a guess. This is what 'add milk to my groceries note' needs."
        let params = [
            NotesTools.noteIdParam, NotesTools.noteTitleParam, NotesTools.folderParam,
            ToolParam("text", "string", "The text to append. Plain text; line breaks are preserved.", required: true),
        ]
        let statusLabel = "Updating note"
        let statusIcon = NotesTools.icon
        let group = NotesTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: NotesTools.icon, title: "Append to note", subtitle: { $0.str("note") ?? $0.str("note_id").map { "id …\($0.suffix(6))" } },
                             fields: [(key: "note", label: "Note", kind: .text, required: false),
                                      (key: "text", label: "Text", kind: .multiline, required: true)],
                             confirmLabel: "Append", layout: .note)
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .fail("text is required") }
            do {
                let (expr, note) = try await NotesApp.reference(id: args.str("note_id"), title: args.str("note"), folder: args.str("folder"))
                try await NotesApp.append(expr: expr, text: text)
                Log.info("Notes append → '\(note.title)'")
                let card = Cards.note(source: "Notes", icon: NotesTools.icon, title: note.title.isEmpty ? "Untitled" : note.title, body: "Added: " + text.preview(140))
                return .ok(["ok": true, "note_id": note.id, "title": note.title], cards: [card], narration: "Added that to \(note.title.isEmpty ? "the note" : note.title).")
            } catch { return NotesApp.fail(error) }
        }
    }
}

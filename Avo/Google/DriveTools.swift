import AppKit
import Foundation
import PDFKit

// MARK: - Google Drive helpers

enum GDrive {
    static let base = "https://www.googleapis.com/drive/v3"
    static let icon = "externaldrive.fill"
    static let group = "Drive"
    static let source = "Google Drive"
    static let fields = "files(id,name,mimeType,modifiedTime,owners(displayName,emailAddress),webViewLink,size,iconLink)"

    static let mimeFamilies: [String: String] = [
        "doc": "application/vnd.google-apps.document",
        "sheet": "application/vnd.google-apps.spreadsheet",
        "slide": "application/vnd.google-apps.presentation",
        "pdf": "application/pdf",
        "folder": "application/vnd.google-apps.folder",
    ]

    static func kind(_ mime: String) -> String {
        switch mime {
        case "application/vnd.google-apps.document": return "Google Doc"
        case "application/vnd.google-apps.spreadsheet": return "Google Sheet"
        case "application/vnd.google-apps.presentation": return "Google Slides"
        case "application/vnd.google-apps.folder": return "Folder"
        case "application/vnd.google-apps.form": return "Google Form"
        case "application/pdf": return "PDF"
        default:
            if mime.hasPrefix("image/") { return "Image" }
            if mime.hasPrefix("text/") { return "Text" }
            if mime.hasPrefix("video/") { return "Video" }
            return mime.split(separator: "/").last.map(String.init) ?? mime
        }
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }

    struct File {
        var id: String; var name: String; var mime: String; var modified: Date?; var owner: String; var link: String?; var size: Int?
        var json: [String: Any] {
            var j: [String: Any] = ["id": id, "name": name, "type": kind(mime), "mime_type": mime, "owner": owner]
            if let modified { j["modified"] = GoogleDates.human(modified, withYear: true) }
            if let link { j["url"] = link }
            if let size { j["size"] = size }
            return j
        }
        var row: GlanceCard.Row {
            var sub = kind(mime)
            if let modified { sub = "\(GoogleDates.relative(modified)) ago · \(sub)" }
            if !owner.isEmpty { sub += " · \(owner)" }
            let icon: String
            switch mime {
            case "application/vnd.google-apps.document": icon = "doc.text.fill"
            case "application/vnd.google-apps.spreadsheet": icon = "tablecells.fill"
            case "application/vnd.google-apps.presentation": icon = "rectangle.on.rectangle.fill"
            case "application/vnd.google-apps.folder": icon = "folder.fill"
            case "application/pdf": icon = "doc.richtext.fill"
            case let m where m.hasPrefix("image/"): icon = "photo.fill"
            default: icon = "doc.fill"
            }
            return .init(title: name, subtitle: sub, icon: icon, trailing: nil, tone: .neutral, url: link)
        }
    }

    static func parse(_ f: [String: Any]) -> File? {
        guard let id = f["id"] as? String else { return nil }
        let owners = f["owners"] as? [[String: Any]] ?? []
        let owner = owners.first.flatMap { ($0["displayName"] as? String) ?? ($0["emailAddress"] as? String) } ?? ""
        return File(id: id, name: f["name"] as? String ?? "", mime: f["mimeType"] as? String ?? "", modified: GoogleDates.parse(f["modifiedTime"] as? String)?.date,
                    owner: owner, link: f["webViewLink"] as? String, size: (f["size"] as? String).flatMap { Int($0) })
    }

    static func list(q: String, orderBy: String? = nil, max: Int) async throws -> [File] {
        var query: [String: Any] = ["q": q, "pageSize": max, "fields": fields, "supportsAllDrives": true, "includeItemsFromAllDrives": true]
        if let orderBy { query["orderBy"] = orderBy }
        let r = try await GoogleAPI.json(.GET, "\(base)/files", query: query)
        return (r["files"] as? [[String: Any]] ?? []).compactMap(parse)
    }

    static func card(_ files: [File], title: String, subtitle: String?) -> CardKind {
        var blocks: [GlanceCard.Block] = [.header(title: title, subtitle: subtitle, icon: icon)]
        if files.isEmpty { blocks.append(.text("No files found.")) } else { blocks.append(.list(rows: files.prefix(6).map { $0.row })) }
        return .glance(GlanceCard(id: UUID(), blocks: blocks, source: source, sourceIcon: icon))
    }

    static func metadata(_ id: String) async throws -> File {
        let r = try await GoogleAPI.json(.GET, "\(base)/files/\(id)", query: ["fields": "id,name,mimeType,modifiedTime,owners(displayName,emailAddress),webViewLink,size", "supportsAllDrives": true])
        guard let f = parse(r) else { throw GoogleAPI.APIError(status: 404, message: "File \(id) not found.") }
        return f
    }

    /// Extracts the Drive file id from a docs.google.com / drive.google.com URL, or returns the input if it already looks like an id.
    static func fileId(from s: String) -> String {
        if let r = s.range(of: #"/d/([A-Za-z0-9_-]{10,})"#, options: .regularExpression) {
            return String(s[r]).replacingOccurrences(of: "/d/", with: "")
        }
        if let u = URLComponents(string: s), let id = u.queryItems?.first(where: { $0.name == "id" })?.value { return id }
        if let r = s.range(of: #"/folders/([A-Za-z0-9_-]{10,})"#, options: .regularExpression) {
            return String(s[r]).replacingOccurrences(of: "/folders/", with: "")
        }
        return s
    }

    /// Returns the file's text content (export for Google formats, download for others).
    static func text(of f: File) async throws -> (text: String, note: String?) {
        switch f.mime {
        case "application/vnd.google-apps.document", "application/vnd.google-apps.presentation":
            let (d, _) = try await GoogleAPI.request(.GET, "\(base)/files/\(f.id)/export", query: ["mimeType": "text/plain"])
            return (String(decoding: d, as: UTF8.self), nil)
        case "application/vnd.google-apps.spreadsheet":
            let (d, _) = try await GoogleAPI.request(.GET, "\(base)/files/\(f.id)/export", query: ["mimeType": "text/csv"])
            let lines = String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let limited = lines.prefix(200).joined(separator: "\n")
            return (limited, lines.count > 200 ? "Only the first 200 rows of the first sheet are included (\(lines.count) rows total)." : "First sheet only, as CSV.")
        case "application/pdf":
            let (d, _) = try await GoogleAPI.request(.GET, "\(base)/files/\(f.id)", query: ["alt": "media", "supportsAllDrives": true])
            guard let pdf = PDFDocument(data: d) else { throw GoogleAPI.APIError(status: 0, message: "Could not parse the PDF.") }
            var out = ""
            for i in 0..<pdf.pageCount { if let s = pdf.page(at: i)?.string { out += s + "\n\n" } }
            return (out, out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The PDF has no extractable text (it may be scanned)." : "\(pdf.pageCount) pages.")
        case "application/vnd.google-apps.folder":
            throw GoogleAPI.APIError(status: 0, message: "\(f.name) is a folder, not a readable file. Use drive_search to list what is inside it.")
        default:
            let readable = f.mime.hasPrefix("text/") || ["application/json", "application/xml", "application/javascript", "application/x-yaml", "application/rtf"].contains(f.mime)
            guard readable else { throw GoogleAPI.APIError(status: 0, message: "\(f.name) is \(kind(f.mime)) (\(f.mime)), which cannot be read as text. Use drive_open to view it.") }
            if let size = f.size, size > 5_000_000 { throw GoogleAPI.APIError(status: 0, message: "\(f.name) is too large to read (\(size / 1_000_000) MB).") }
            let (d, _) = try await GoogleAPI.request(.GET, "\(base)/files/\(f.id)", query: ["alt": "media", "supportsAllDrives": true])
            return (String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self), nil)
        }
    }
}

// MARK: - Tools

struct DriveSearch: Tool {
    let name = "drive_search"
    let description = "Search the user's Google Drive by file name and full text (contents of Docs, Sheets, Slides, PDFs and other indexed files). Optionally restrict to a type (doc, sheet, slide, pdf, folder), a folder, or files modified after a date. Returns up to 15 files with an `id` (for drive_read_file / drive_open), name, type, owner, last modified and a link; results are shown to the user as a clickable list. Use for 'find my budget spreadsheet', 'the doc about onboarding', 'PDFs from last month'."
    let params = [
        ToolParam("query", "string", "Words to match in the file name or contents. Keep it short and distinctive. Omit when filtering only by type/date/folder."),
        ToolParam("type", "string", "Restrict to one kind of file.", enumValues: ["doc", "sheet", "slide", "pdf", "folder", "any"]),
        ToolParam("name_only", "boolean", "Match only the file name, not the contents. Default false."),
        ToolParam("modified_after", "string", "Only files modified after this ISO 8601 date, e.g. '2026-08-01'."),
        ToolParam("folder_id", "string", "Only files directly inside this folder (a folder id from a previous result). Omit to search everywhere."),
        ToolParam("max_results", "integer", "How many results, 1–15. Default 10."),
    ]
    let statusLabel = "Searching Drive"
    let statusIcon = GDrive.icon
    let group = GDrive.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            var clauses = ["trashed = false"]
            let q = GoogleAPI.trimmed(args["query"])
            if let q {
                let e = GDrive.escape(q)
                clauses.append(GoogleAPI.bool(args["name_only"]) ? "name contains '\(e)'" : "(name contains '\(e)' or fullText contains '\(e)')")
            }
            if let t = GoogleAPI.trimmed(args["type"])?.lowercased(), let mime = GDrive.mimeFamilies[t] { clauses.append("mimeType = '\(mime)'") }
            if let m = GoogleDates.parse(GoogleAPI.trimmed(args["modified_after"])) { clauses.append("modifiedTime > '\(GoogleDates.rfc3339(m.date))'") }
            if let f = GoogleAPI.trimmed(args["folder_id"]) { clauses.append("'\(GDrive.escape(GDrive.fileId(from: f)))' in parents") }
            guard clauses.count > 1 else { return .fail("Nothing to search for.", guidance: "Pass query, type, modified_after or folder_id (or use drive_recent_files).") }
            let files = try await GDrive.list(q: clauses.joined(separator: " and "), orderBy: q == nil ? "modifiedTime desc" : nil, max: GoogleAPI.int(args["max_results"], default: 10, max: 15))
            return .ok(["ok": true, "count": files.count, "files": files.map { $0.json }],
                       cards: [GDrive.card(files, title: "Drive", subtitle: q.map { "matching “\($0)”" } ?? "\(files.count) files")])
        }
    }
}

struct DriveRecentFiles: Tool {
    let name = "drive_recent_files"
    let description = "List the files the user most recently opened or edited in Google Drive, newest first. Use for 'what was I working on?', 'open my latest doc', or when the user refers to 'that spreadsheet' without a name. Returns ids for drive_read_file / drive_open; shown to the user as a clickable list."
    let params = [
        ToolParam("type", "string", "Restrict to one kind of file.", enumValues: ["doc", "sheet", "slide", "pdf", "folder", "any"]),
        ToolParam("max_results", "integer", "How many results, 1–15. Default 10."),
    ]
    let statusLabel = "Listing recent files"
    let statusIcon = GDrive.icon
    let group = GDrive.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            var clauses = ["trashed = false"]
            if let t = GoogleAPI.trimmed(args["type"])?.lowercased(), let mime = GDrive.mimeFamilies[t] { clauses.append("mimeType = '\(mime)'") }
            let files = try await GDrive.list(q: clauses.joined(separator: " and "), orderBy: "recency desc", max: GoogleAPI.int(args["max_results"], default: 10, max: 15))
            return .ok(["ok": true, "count": files.count, "files": files.map { $0.json }], cards: [GDrive.card(files, title: "Recent files", subtitle: nil)])
        }
    }
}

struct DriveReadFile: Tool {
    let name = "drive_read_file"
    let description = "Read the text of a Google Drive file: Google Docs and Slides as plain text, Sheets as CSV (first sheet, up to 200 rows), PDFs with their text extracted, plus plain-text files. Takes the file `id` from drive_search or drive_recent_files (a Docs/Drive URL also works). Long files are paged with `offset`; the result tells you if there is more. Use for 'summarize that doc', 'what does the spreadsheet say', 'read the PDF'."
    let params = [
        ToolParam("file_id", "string", "The file id from drive_search / drive_recent_files, or a docs.google.com / drive.google.com URL.", required: true),
        ToolParam("offset", "integer", "Character offset to start from, for long files. Default 0."),
        ToolParam("max_chars", "integer", "Maximum characters to return. Default 8000."),
    ]
    let statusLabel = "Reading file"
    let statusIcon = "doc.text"
    let group = GDrive.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let raw = GoogleAPI.trimmed(args["file_id"]) else { return .fail("file_id is required.") }
            let f = try await GDrive.metadata(GDrive.fileId(from: raw))
            let (text, note) = try await GDrive.text(of: f)
            let offset = Swift.max(0, GoogleAPI.int(args["offset"], default: 1) - 1)
            let maxChars = GoogleAPI.int(args["max_chars"], default: 8000, max: 60000)
            let start = min(offset, text.count)
            let slice = String(text.dropFirst(start).prefix(maxChars))
            var j: [String: Any] = ["ok": true, "id": f.id, "name": f.name, "type": GDrive.kind(f.mime), "url": f.link ?? "", "text": slice, "total_chars": text.count]
            if let note { j["note"] = note }
            if start + slice.count < text.count { j["next_offset"] = start + slice.count; j["note"] = ((note ?? "") + " Truncated; call again with offset=\(start + slice.count) for more.").trimmingCharacters(in: .whitespaces) }
            let card = CardKind.glance(GlanceCard(id: UUID(), blocks: [
                .header(title: f.name, subtitle: GDrive.kind(f.mime) + (f.modified.map { " · \(GoogleDates.relative($0)) ago" } ?? ""), icon: "doc.text"),
                .text(String(slice.prefix(240)).replacingOccurrences(of: "\n\n", with: "\n") + (slice.count > 240 ? "…" : "")),
            ], source: GDrive.source, sourceIcon: GDrive.icon))
            return .ok(j, cards: [card])
        }
    }
}

struct DriveOpen: Tool {
    let name = "drive_open"
    let description = "Open a Google Drive file in the user's default browser (the Docs/Sheets/Slides editor, Drive preview, or the folder). Takes the file `id` from drive_search or drive_recent_files, or a Drive/Docs URL. Use for 'open that doc', 'pull up my budget sheet'. Find the file first if you only have a name."
    let params = [
        ToolParam("file_id", "string", "The file id from drive_search / drive_recent_files, or a docs.google.com / drive.google.com URL.", required: true),
    ]
    let statusLabel = "Opening"
    let statusIcon = "arrow.up.forward.app"
    let group = GDrive.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let raw = GoogleAPI.trimmed(args["file_id"]) else { return .fail("file_id is required.") }
            let f = try await GDrive.metadata(GDrive.fileId(from: raw))
            guard let link = f.link, let url = URL(string: link) else { return .fail("\(f.name) has no web link.") }
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
            return .ok(["ok": true, "id": f.id, "name": f.name, "opened": link])
        }
    }
}

struct DriveCreateDoc: Tool {
    let name = "drive_create_doc"
    let description = "Create a NEW Google Doc in the user's Drive from a title and plain-text body, and return its link. YOU write the body text. Use for 'make a doc with these notes', 'start a Google Doc called Q3 plan'. Not for editing an existing document."
    let params = [
        ToolParam("title", "string", "Document title.", required: true),
        ToolParam("body", "string", "Plain-text content of the document. Paragraphs separated by blank lines.", required: true),
        ToolParam("folder_id", "string", "Optional folder id (from drive_search) to create the doc in. Omit for My Drive root."),
    ]
    let confirmation: ConfirmationSpec? = ConfirmationSpec(
        icon: "doc.badge.plus", title: "Create Google Doc",
        subtitle: { a in JSON.string(a["title"]) },
        fields: [("title", "Title", .text, true), ("body", "Body", .multiline, true)],
        confirmLabel: "Create")
    let statusLabel = "Creating doc"
    let statusIcon = "doc.badge.plus"
    let group = GDrive.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let title = GoogleAPI.trimmed(args["title"]) else { return .fail("title is required.") }
            guard let body = JSON.string(args["body"]), !body.isEmpty else { return .fail("body is required.") }
            var meta: [String: Any] = ["name": title, "mimeType": "application/vnd.google-apps.document"]
            if let folder = GoogleAPI.trimmed(args["folder_id"]) { meta["parents"] = [GDrive.fileId(from: folder)] }
            let boundary = "avo-\(UUID().uuidString)"
            var data = Data()
            data.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
            data.append(try JSONSerialization.data(withJSONObject: meta))
            data.append(Data("\r\n--\(boundary)\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n".utf8))
            data.append(Data(body.utf8))
            data.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let r = try await GoogleAPI.json(.POST, "https://www.googleapis.com/upload/drive/v3/files",
                                             query: ["uploadType": "multipart", "fields": "id,name,mimeType,modifiedTime,owners(displayName,emailAddress),webViewLink", "supportsAllDrives": true],
                                             raw: GoogleAPI.RawBody(data: data, contentType: "multipart/related; boundary=\(boundary)"))
            guard let f = GDrive.parse(r) else { return .fail("Google created the document but returned an unexpected response.") }
            return .ok(["ok": true, "id": f.id, "name": f.name, "url": f.link ?? ""], cards: [GDrive.card([f], title: "Doc created", subtitle: nil)])
        }
    }
}

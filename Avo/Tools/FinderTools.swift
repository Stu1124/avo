import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Finder / file-system tools. Spotlight via mdfind, text extraction via PDFKit and textutil.
enum FinderTools {
    static let group = "Finder"
    static let icon = "app:com.apple.finder"
    static let pageSize = 6000
    static let excludedPathParts = ["/node_modules/", "/.git/", "/Library/", "/.Trash/", "/.cache/", "/DerivedData/", "/.npm/", "/.cargo/"]

    static func all() -> [Tool] {
        [Search(), ListFolder(), ReadFile(), GetInfo(), OpenFile(), RecentFiles(), CreateFolder(), CreateFile(), Move(), Copy(), Trash()]
    }

    // MARK: file metadata

    struct Info {
        var name: String; var path: String; var isDir: Bool; var size: Int64?; var modified: Date?; var created: Date?; var kind: String; var hidden: Bool
        var json: [String: Any] {
            var j: [String: Any] = ["name": name, "path": path, "kind": kind]
            if let m = modified { j["modified"] = HDate.human(m) }
            if let s = size, !isDir { j["size"] = FinderTools.sizeString(s) }
            if isDir { j["folder"] = true }
            return j
        }
        var file: FilesCard.File { .init(name: name, path: path, kind: kind, modified: modified, size: isDir ? nil : size) }
    }

    static func info(_ path: String) -> Info? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .isHiddenKey, .isPackageKey]) else { return nil }
        let isDir = (v.isDirectory ?? false) && !(v.isPackage ?? false)
        let ext = url.pathExtension.lowercased()
        var kind = v.localizedTypeDescription ?? (ext.isEmpty ? "File" : ext.uppercased())
        if isDir { kind = "Folder" }
        return Info(name: url.lastPathComponent, path: url.path, isDir: isDir, size: v.fileSize.map(Int64.init), modified: v.contentModificationDate,
                    created: v.creationDate, kind: kind, hidden: v.isHidden ?? false)
    }

    static func sizeString(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func filesCard(_ title: String, _ items: [Info]) -> CardKind {
        .files(FilesCard(id: UUID(), title: title, files: items.prefix(8).map(\.file)))
    }

    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
    static func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
    static func short(_ p: String) -> String { p.hasPrefix(Paths.home.path) ? "~" + p.dropFirst(Paths.home.path.count) : p }

    // MARK: Full Disk Access

    /// True when the file system refuses the path outright rather than saying it is not there.
    /// TCC answers `access(2)` with `EPERM` for a protected location (Mail, Messages, Safari, the
    /// AddressBook stores, other apps' containers), while a genuine miss gives `ENOENT`. Telling the
    /// two apart is what stops a permission problem from being reported as "file not found".
    static func permissionDenied(_ p: String) -> Bool {
        guard access(p, R_OK) != 0 else { return false }
        return errno == EPERM || errno == EACCES
    }

    /// Call before reporting a read as missing or unreadable. When macOS refused the path and Avo
    /// has no Full Disk Access, this puts the permission card in the notch and hands back the
    /// failure to return; otherwise it returns nil and the caller reports its own error.
    static func fullDiskGate(_ p: String) async -> ToolResult? {
        guard permissionDenied(p), !Permissions.fullDiskAccess else { return nil }
        _ = await PermissionGate.ensure(.fullDiskAccess)
        return PermissionGate.failure(.fullDiskAccess)
    }

    static func typePredicate(_ t: String) -> String? {
        let x = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        switch x {
        case "pdf": return "kMDItemContentType == \"com.adobe.pdf\""
        case "image", "images", "photo", "photos": return "kMDItemContentTypeTree == \"public.image\""
        case "video", "videos", "movie": return "kMDItemContentTypeTree == \"public.movie\""
        case "audio", "music": return "kMDItemContentTypeTree == \"public.audio\""
        case "presentation", "slides": return "(kMDItemContentTypeTree == \"public.presentation\" || kMDItemFSName == \"*.key\"c || kMDItemFSName == \"*.pptx\"c)"
        case "spreadsheet": return "(kMDItemContentTypeTree == \"public.spreadsheet\" || kMDItemFSName == \"*.numbers\"c || kMDItemFSName == \"*.xlsx\"c)"
        case "folder", "folders", "directory": return "kMDItemContentType == \"public.folder\""
        case "text": return "kMDItemContentTypeTree == \"public.text\""
        case "": return nil
        default: return "kMDItemFSName == \"*.\(x)\"c"
        }
    }

    static func mdEscape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    static func isoUTC(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }

    static func mdfind(_ query: String, folder: String?, limit: Int, excludeLibrary: Bool) async throws -> [Info] {
        var args: [String] = []
        if let f = folder { args += ["-onlyin", f] }
        args.append(query)
        Log.info("mdfind \(args.joined(separator: " "))")
        let r = try await Shell.run("/usr/bin/mdfind", args, timeout: 15)
        if r.status != 0 && r.stdout.isEmpty { throw Shell.Failure(message: r.stderr.isEmpty ? "mdfind failed" : r.stderr) }
        var seen = Set<String>()
        var out: [Info] = []
        for line in r.stdout.split(separator: "\n").prefix(600) {
            let p = String(line)
            guard !p.isEmpty, !seen.contains(p) else { continue }
            seen.insert(p)
            if excludeLibrary, excludedPathParts.contains(where: { p.contains($0) }) { continue }
            if let i = info(p), !i.hidden { out.append(i) }
        }
        out.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return Array(out.prefix(limit))
    }

    static func appURL(named name: String) -> URL? { AppFinder.shared.find(name) }

    // MARK: text extraction

    static let textutilExts: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "webarchive", "wordml"]
    static let plainExts: Set<String> = ["txt", "md", "markdown", "json", "csv", "tsv", "xml", "yaml", "yml", "log", "swift", "py", "js", "ts", "tsx", "jsx", "html", "htm", "css", "sh", "toml", "ini", "cfg", "conf", "tex", "sql", "rb", "go", "rs", "java", "c", "h", "m", "cpp", "hpp", "plist", "env", "gitignore"]

    static func extractText(_ path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw Shell.Failure(message: "Could not open PDF") }
            var s = ""
            for i in 0..<doc.pageCount { if let t = doc.page(at: i)?.string { s += t + "\n\n" }; if s.count > 400_000 { break } }
            return s
        }
        if textutilExts.contains(ext) {
            let r = try await Shell.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", path], timeout: 20)
            if r.status != 0 { throw Shell.Failure(message: r.stderr.isEmpty ? "textutil failed" : r.stderr) }
            return r.stdout
        }
        let ut = UTType(filenameExtension: ext)
        let looksText = plainExts.contains(ext) || (ut?.conforms(to: .text) ?? false) || ext.isEmpty
        guard looksText else { throw Shell.Failure(message: "\(url.lastPathComponent) is a \(info(path)?.kind ?? ext) file; Avo can read text, PDF, and Word documents. Use finder_open_file to open it.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count < 20_000_000 else { throw Shell.Failure(message: "File is too large to read (\(sizeString(Int64(data.count))))") }
        if let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) { return s }
        throw Shell.Failure(message: "Not a text file")
    }

    static func resolveDestination(_ src: String, _ dest: String) -> String {
        let d = dest.expandingTilde
        if isDir(d) || d.hasSuffix("/") { return (d as NSString).appendingPathComponent((src as NSString).lastPathComponent) }
        return d
    }

    // MARK: tools

    struct Search: Tool {
        let name = "finder_search"
        let description = "Search the user's files with Spotlight (like Finder's search box): matches file names AND words inside documents. Use for 'find my tax PDF', 'where's the essay about Jan Both', 'search for files named budget'. Supports type, folder and modified-date filters. Results are shown to the user as a visual file list; return the paths you need for follow-up tools (finder_read_file, finder_open_file)."
        let params = [
            ToolParam("query", "string", "The search text: part of a file's name, or wording that occurs somewhere in the document's contents.", required: true),
            ToolParam("scope", "string", "Restricts matching to names alone or to the text inside documents alone; 'all' covers both and is what applies when this is left out.", enumValues: ["all", "names", "content"]),
            ToolParam("types", "array", "Optional. Limits results by kind. Recognised values are pdf, doc, docx, md, txt, csv, spreadsheet, presentation, image, audio, video and folder; a plain extension such as 'numbers' also works.", items: "string"),
            ToolParam("folder", "string", "Optional. Confines the search to one directory, '~/Documents' for example. Leave it unset and the whole disk is searched."),
            ToolParam("modified_after", "string", "Drops anything last changed before this ISO-formatted date; write it as '2026-01-01'."),
            ToolParam("modified_before", "string", "Cuts off anything last changed after this ISO-formatted date."),
            ToolParam("limit", "integer", "Maximum results (default 20)."),
        ]
        let statusLabel = "Searching files"
        let statusIcon = "magnifyingglass"
        let group = FinderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let q = args.str("query") else { return .fail("query is required") }
            let scope = args.str("scope") ?? "all"
            let e = FinderTools.mdEscape(q)
            var clauses: [String] = []
            switch scope {
            case "names": clauses.append("kMDItemFSName == \"*\(e)*\"cd")
            case "content": clauses.append("kMDItemTextContent == \"\(e)*\"cd")
            default: clauses.append("(kMDItemFSName == \"*\(e)*\"cd || kMDItemTextContent == \"\(e)*\"cd)")
            }
            if let types = args.strings("types") {
                let preds = types.compactMap(FinderTools.typePredicate)
                if !preds.isEmpty { clauses.append("(" + preds.joined(separator: " || ") + ")") }
            }
            if let a = args.str("modified_after") {
                guard let d = HDate.parse(a, defaultHour: 0) else { return .fail("Bad modified_after date '\(a)'") }
                clauses.append("kMDItemFSContentChangeDate >= $time.iso(\(FinderTools.isoUTC(d)))")
            }
            if let b = args.str("modified_before") {
                guard let d = HDate.parse(b, defaultHour: 23) else { return .fail("Bad modified_before date '\(b)'") }
                clauses.append("kMDItemFSContentChangeDate <= $time.iso(\(FinderTools.isoUTC(d)))")
            }
            var folder: String?
            if let f = args.str("folder") {
                folder = f.expandingTilde
                guard FinderTools.isDir(folder!) else { return .fail("Folder not found: \(f)") }
            }
            let limit = min(max(args.int("limit") ?? 20, 1), 50)
            do {
                let items = try await FinderTools.mdfind(clauses.joined(separator: " && "), folder: folder, limit: limit, excludeLibrary: !(folder?.contains("/Library") ?? false))
                Log.info("finder_search '\(q)' → \(items.count)")
                let cards: [CardKind] = items.isEmpty ? [] : [FinderTools.filesCard("\"\(q)\" · \(items.count) result\(items.count == 1 ? "" : "s")", items)]
                return .ok(["ok": true, "count": items.count, "files": items.map(\.json)], cards: cards)
            } catch { return .fail("Search failed: \(error)") }
        }
    }

    struct ListFolder: Tool {
        let name = "finder_list_folder"
        let description = "List the contents of a folder (files and subfolders with kind, size and modified date), like opening it in Finder. Use for 'what's in my Downloads', 'show me my Desktop', 'list the files in ~/Documents/Notes'. Folders are shown before files."
        let params = [
            ToolParam("path", "string", "Which directory to read — '~/Downloads', say.", required: true),
            ToolParam("limit", "integer", "Maximum entries to return (default 60)."),
            ToolParam("show_hidden", "boolean", "Include dot-files. Defaults to false."),
        ]
        let statusLabel = "Listing folder"
        let statusIcon = "folder"
        let group = FinderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path") else { return .fail("path is required") }
            let p = raw.expandingTilde
            guard FinderTools.isDir(p) else {
                if let gate = await FinderTools.fullDiskGate(p) { return gate }
                return .fail("Folder not found: \(raw)", guidance: "Use finder_search to locate it; never guess paths.")
            }
            let showHidden = args.bool("show_hidden") ?? false
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: p) else {
                if let gate = await FinderTools.fullDiskGate(p) { return gate }
                return .fail("Cannot read \(raw)")
            }
            var items = names.compactMap { FinderTools.info((p as NSString).appendingPathComponent($0)) }.filter { showHidden || !$0.hidden }
            items.sort { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            let limit = min(max(args.int("limit") ?? 60, 1), 200)
            let shown = Array(items.prefix(limit))
            Log.info("finder_list_folder \(FinderTools.short(p)) → \(items.count)")
            return .ok(["ok": true, "path": p, "count": items.count, "entries": shown.map(\.json)],
                       cards: [FinderTools.filesCard("\(FinderTools.short(p)) · \(items.count) item\(items.count == 1 ? "" : "s")", shown)])
        }
    }

    struct ReadFile: Tool {
        let name = "finder_read_file"
        let description = "Read the text of a file: plain text, Markdown, code, CSV, PDF (text extracted), and Word documents (doc/docx/rtf/odt). Returns up to 6000 characters per call; when `has_more` is true, call again with `offset` = `next_offset` to page through. Use for 'summarize this PDF', 'what does my essay say', 'read the notes file'."
        let params = [
            ToolParam("path", "string", "Full path of the file (from finder_search / finder_list_folder / finder_recent_files).", required: true),
            ToolParam("offset", "integer", "Where in the text to resume reading, counted in characters — the way to walk through a document too long for one call. Starts at 0."),
        ]
        let statusLabel = "Reading file"
        let statusIcon = "doc.text"
        let group = FinderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path") else { return .fail("path is required") }
            let p = raw.expandingTilde
            guard FinderTools.exists(p) else {
                if let gate = await FinderTools.fullDiskGate(p) { return gate }
                return .fail("File not found: \(raw)", guidance: "Use finder_search to locate it; never guess paths.")
            }
            guard !FinderTools.isDir(p) else { return .fail("\(raw) is a folder; use finder_list_folder.") }
            do {
                let full = try await FinderTools.extractText(p)
                let chars = Array(full)
                let offset = min(max(args.int("offset") ?? 0, 0), chars.count)
                let end = min(offset + FinderTools.pageSize, chars.count)
                let page = String(chars[offset..<end])
                Log.info("finder_read_file \(FinderTools.short(p)) chars \(offset)-\(end)/\(chars.count)")
                var j: [String: Any] = ["ok": true, "path": p, "name": (p as NSString).lastPathComponent, "text": page, "offset": offset, "total_chars": chars.count, "has_more": end < chars.count]
                if end < chars.count { j["next_offset"] = end }
                return .ok(j)
            } catch {
                if let gate = await FinderTools.fullDiskGate(p) { return gate }
                return .fail("\(error)")
            }
        }
    }

    struct GetInfo: Tool {
        let name = "finder_get_info"
        let description = "Get details about a file or folder: kind, size, created and modified dates, and for folders the item count. Use for 'how big is this file', 'when did I last edit my essay'."
        let params = [ToolParam("path", "string", "Full path of the file or folder.", required: true)]
        let statusLabel = "Getting info"
        let statusIcon = "info.circle"
        let group = FinderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path") else { return .fail("path is required") }
            let p = raw.expandingTilde
            guard let i = FinderTools.info(p) else { return .fail("Not found: \(raw)", guidance: "Use finder_search to locate it; never guess paths.") }
            var j = i.json; j["ok"] = true
            if let c = i.created { j["created"] = HDate.human(c) }
            var pairs: [(String, String)] = [("Kind", i.kind)]
            if i.isDir {
                let n = (try? FileManager.default.contentsOfDirectory(atPath: p))?.filter { !$0.hasPrefix(".") }.count ?? 0
                j["items"] = n; pairs.append(("Items", "\(n)"))
            } else if let s = i.size { pairs.append(("Size", FinderTools.sizeString(s))) }
            if let m = i.modified { pairs.append(("Modified", HDate.human(m))) }
            if let c = i.created { pairs.append(("Created", HDate.human(c))) }
            pairs.append(("Where", FinderTools.short((p as NSString).deletingLastPathComponent)))
            let card = CardKind.glance(GlanceCard(id: UUID(), blocks: [.header(title: i.name, subtitle: nil, icon: i.isDir ? "folder.fill" : "doc.fill"), .keyValue(pairs: pairs)], source: "Finder", sourceIcon: FinderTools.icon))
            return .ok(j, cards: [card])
        }
    }

    struct OpenFile: Tool {
        let name = "finder_open_file"
        let description = "Open a file or folder in its default app (or a specific app), or reveal it in a Finder window. Use for 'open that PDF', 'open the essay in Pages', 'show it in Finder'. Pass the exact path from a previous finder_* result."
        let params = [
            ToolParam("path", "string", "Full path of the file or folder to open.", required: true),
            ToolParam("app", "string", "Optional. Names an app to use in place of the system default, spelled the way the user said it — 'Preview', say. Ignored when reveal_in_finder is true."),
            ToolParam("reveal_in_finder", "boolean", "When true, a Finder window opens with the item highlighted rather than the file being handed to an app. False unless set."),
        ]
        let statusLabel = "Opening"
        let statusIcon = "arrow.up.forward.app"
        let group = FinderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path") else { return .fail("path is required") }
            let p = raw.expandingTilde
            guard FinderTools.exists(p) else { return .fail("Not found: \(raw)", guidance: "Use finder_search to locate it; never guess paths.") }
            let url = URL(fileURLWithPath: p)
            if args.bool("reveal_in_finder") ?? false {
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Log.info("finder_open_file reveal \(FinderTools.short(p))")
                return .ok(["ok": true, "revealed": p])
            }
            if let appName = args.str("app") {
                guard let appURL = FinderTools.appURL(named: appName) else { return .fail("App '\(appName)' is not installed.", guidance: "Offer to open with the default app instead.") }
                let ok: Bool = await withCheckedContinuation { cont in
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { app, err in cont.resume(returning: err == nil && app != nil) }
                }
                Log.info("finder_open_file \(FinderTools.short(p)) with \(appURL.lastPathComponent) ok=\(ok)")
                return ok ? .ok(["ok": true, "opened": p, "app": appURL.deletingPathExtension().lastPathComponent]) : .fail("\(appURL.deletingPathExtension().lastPathComponent) could not open \(raw).")
            }
            let ok = await MainActor.run { NSWorkspace.shared.open(url) }
            Log.info("finder_open_file \(FinderTools.short(p)) ok=\(ok)")
            return ok ? .ok(["ok": true, "opened": p]) : .fail("Could not open \(raw).")
        }
    }

    struct RecentFiles: Tool {
        let name = "finder_recent_files"
        let description = "List files the user recently modified (like Finder's Recents), newest first, excluding system/library and developer cache folders. Use for 'what did I work on today', 'show my recent downloads', 'files from this week'."
        let params = [
            ToolParam("days", "integer", "Look back this many days. Defaults to 7."),
            ToolParam("modified_after", "string", "Excludes anything last changed before this ISO-formatted date. Where it is absent the cutoff sits a week back, and supplying it overrides `days`."),
            ToolParam("folder", "string", "Optional. Which directory to walk — '~/Desktop' for instance. The user's home directory is used when nothing is given."),
            ToolParam("types", "array", "Optional. Kind filters, drawn from the same set finder_search accepts.", items: "string"),
            ToolParam("limit", "integer", "Maximum results (default 20)."),
        ]
        let statusLabel = "Finding recent files"
        let statusIcon = "clock"
        let group = FinderTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            var since = Date().addingTimeInterval(-Double(max(args.int("days") ?? 7, 1)) * 86400)
            if let a = args.str("modified_after"), let d = HDate.parse(a, defaultHour: 0) { since = d }
            let folder = (args.str("folder") ?? "~").expandingTilde
            guard FinderTools.isDir(folder) else {
                if let gate = await FinderTools.fullDiskGate(folder) { return gate }
                return .fail("Folder not found: \(folder)")
            }
            var clauses = ["kMDItemFSContentChangeDate >= $time.iso(\(FinderTools.isoUTC(since)))", "kMDItemContentType != \"public.folder\""]
            if let types = args.strings("types") {
                let preds = types.compactMap(FinderTools.typePredicate)
                if !preds.isEmpty { clauses.append("(" + preds.joined(separator: " || ") + ")") }
            }
            let limit = min(max(args.int("limit") ?? 20, 1), 50)
            do {
                let items = try await FinderTools.mdfind(clauses.joined(separator: " && "), folder: folder, limit: limit, excludeLibrary: true)
                Log.info("finder_recent_files since \(HDate.human(since)) in \(FinderTools.short(folder)) → \(items.count)")
                return .ok(["ok": true, "since": HDate.human(since), "count": items.count, "files": items.map(\.json)],
                           cards: items.isEmpty ? [] : [FinderTools.filesCard("Recent · \(FinderTools.short(folder))", items)])
            } catch { return .fail("Search failed: \(error)") }
        }
    }

    struct CreateFolder: Tool {
        let name = "finder_create_folder"
        let description = "Create a new folder at a path. Use for 'make a folder called Taxes 2026 in Documents'. Fails if it already exists."
        let params = [
            ToolParam("path", "string", "Where the new directory should go, '~/Documents/Taxes 2026' for instance.", required: true),
            ToolParam("create_parents", "boolean", "When true, any parent directories that do not yet exist are made along the way. Off unless set."),
        ]
        let statusLabel = "Creating folder"
        let statusIcon = "folder.badge.plus"
        let group = FinderTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: FinderTools.icon, title: "New folder", subtitle: { $0.str("path").map(FinderTools.short) },
                             fields: [(key: "path", label: "Path", kind: .text, required: true)], confirmLabel: "Create")
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path") else { return .fail("path is required") }
            let p = raw.expandingTilde
            if FinderTools.exists(p) { return .fail("Already exists: \(FinderTools.short(p))") }
            do {
                try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: args.bool("create_parents") ?? false)
                Log.info("finder_create_folder \(FinderTools.short(p))")
                return .ok(["ok": true, "path": p], cards: [FinderTools.filesCard("Created", [FinderTools.info(p)].compactMap { $0 })])
            } catch { return .fail("Could not create folder: \(error.localizedDescription)", guidance: "The parent folder may not exist; retry with create_parents=true if the user agrees.") }
        }
    }

    struct CreateFile: Tool {
        let name = "finder_create_file"
        let description = "Create a new text file at a path, optionally with content. Use for 'make a notes.md on my Desktop with these lines'. Fails if the file already exists."
        let params = [
            ToolParam("path", "string", "Where the new file should go, '~/Desktop/notes.md' for instance.", required: true),
            ToolParam("content", "string", "Optional. Text to write into it, encoded as UTF-8."),
        ]
        let statusLabel = "Creating file"
        let statusIcon = "doc.badge.plus"
        let group = FinderTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: FinderTools.icon, title: "New file", subtitle: { $0.str("path").map(FinderTools.short) },
                             fields: [(key: "path", label: "Path", kind: .text, required: true), (key: "content", label: "Content", kind: .multiline, required: false)], confirmLabel: "Create")
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path") else { return .fail("path is required") }
            let p = raw.expandingTilde
            if FinderTools.exists(p) { return .fail("Already exists: \(FinderTools.short(p))") }
            guard FinderTools.isDir((p as NSString).deletingLastPathComponent) else { return .fail("Parent folder does not exist.", guidance: "Create it first with finder_create_folder.") }
            let content = (args["content"] as? String) ?? ""
            do {
                try content.write(toFile: p, atomically: true, encoding: .utf8)
                Log.info("finder_create_file \(FinderTools.short(p)) (\(content.count) chars)")
                return .ok(["ok": true, "path": p, "chars": content.count], cards: [FinderTools.filesCard("Created", [FinderTools.info(p)].compactMap { $0 })])
            } catch { return .fail("Could not write file: \(error.localizedDescription)") }
        }
    }

    struct Move: Tool {
        let name = "finder_move"
        let description = "Move or rename a file or folder. Pass the source path and either a folder to move it into or a full new path (rename). Refuses to overwrite."
        let params = [
            ToolParam("path", "string", "The file or folder to move.", required: true),
            ToolParam("destination", "string", "Either the full path it should end up at, or a directory that already exists to move it inside.", required: true),
        ]
        let statusLabel = "Moving"
        let statusIcon = "arrow.right.doc.on.clipboard"
        let group = FinderTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: FinderTools.icon, title: "Move", subtitle: { $0.str("path").map { ($0 as NSString).lastPathComponent } },
                             fields: [(key: "path", label: "From", kind: .text, required: true), (key: "destination", label: "To", kind: .text, required: true)], confirmLabel: "Move")
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path"), let destRaw = args.str("destination") else { return .fail("path and destination are required") }
            let src = raw.expandingTilde
            guard FinderTools.exists(src) else { return .fail("Not found: \(raw)", guidance: "Use finder_search to locate it; never guess paths.") }
            let dest = FinderTools.resolveDestination(src, destRaw)
            if FinderTools.exists(dest) { return .fail("Something already exists at \(FinderTools.short(dest)).") }
            do {
                try FileManager.default.moveItem(atPath: src, toPath: dest)
                Log.info("finder_move \(FinderTools.short(src)) → \(FinderTools.short(dest))")
                return .ok(["ok": true, "from": src, "to": dest], cards: [FinderTools.filesCard("Moved", [FinderTools.info(dest)].compactMap { $0 })])
            } catch { return .fail("Move failed: \(error.localizedDescription)") }
        }
    }

    struct Copy: Tool {
        let name = "finder_copy"
        let description = "Copy a file or folder to another location. Pass the source path and either a folder to copy into or a full destination path. Refuses to overwrite."
        let params = [
            ToolParam("path", "string", "The file or folder to copy.", required: true),
            ToolParam("destination", "string", "Either the full path the copy should end up at, or a directory that already exists for the item to be copied inside, such as '~/Documents/Archive'.", required: true),
        ]
        let statusLabel = "Copying"
        let statusIcon = "doc.on.doc"
        let group = FinderTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: FinderTools.icon, title: "Copy", subtitle: { $0.str("path").map { ($0 as NSString).lastPathComponent } },
                             fields: [(key: "path", label: "From", kind: .text, required: true), (key: "destination", label: "To", kind: .text, required: true)], confirmLabel: "Copy")
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path"), let destRaw = args.str("destination") else { return .fail("path and destination are required") }
            let src = raw.expandingTilde
            guard FinderTools.exists(src) else { return .fail("Not found: \(raw)", guidance: "Use finder_search to locate it; never guess paths.") }
            let dest = FinderTools.resolveDestination(src, destRaw)
            if FinderTools.exists(dest) { return .fail("Something already exists at \(FinderTools.short(dest)).") }
            do {
                try FileManager.default.copyItem(atPath: src, toPath: dest)
                Log.info("finder_copy \(FinderTools.short(src)) → \(FinderTools.short(dest))")
                return .ok(["ok": true, "from": src, "to": dest], cards: [FinderTools.filesCard("Copied", [FinderTools.info(dest)].compactMap { $0 })])
            } catch { return .fail("Copy failed: \(error.localizedDescription)") }
        }
    }

    struct Trash: Tool {
        let name = "finder_trash"
        let description = "Move a file or folder to the Trash (recoverable from the Trash; nothing is permanently deleted). Use for 'delete that file', 'trash the old drafts folder'. Always pass the exact path from a previous finder_* result."
        let params = [ToolParam("path", "string", "The file or folder to move to the Trash.", required: true)]
        let statusLabel = "Trashing"
        let statusIcon = "trash"
        let group = FinderTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: FinderTools.icon, title: "Move to Trash", subtitle: { $0.str("path").map { ($0 as NSString).lastPathComponent } },
                             fields: [(key: "path", label: "Path", kind: .text, required: true)], confirmLabel: "Trash", destructive: true)
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let raw = args.str("path") else { return .fail("path is required") }
            let p = raw.expandingTilde
            guard FinderTools.exists(p) else { return .fail("Not found: \(raw)", guidance: "Use finder_search to locate it; never guess paths.") }
            guard p != Paths.home.path, p.count > 3 else { return .fail("Refusing to trash \(p).") }
            do {
                var result: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &result)
                Log.info("finder_trash \(FinderTools.short(p))")
                return .ok(["ok": true, "trashed": p, "now_at": result?.path ?? ""],
                           cards: [Cards.glance(source: "Finder", icon: FinderTools.icon, header: ("Moved to Trash", (p as NSString).lastPathComponent))])
            } catch { return .fail("Could not trash: \(error.localizedDescription)") }
        }
    }
}

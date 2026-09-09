import AppKit
import Foundation

// MARK: - Contacts name resolution

/// Resolves phone numbers / emails to contact names by reading the local AddressBook databases
/// directly. Loads once, caches in memory.
///
/// Avo asks for no Contacts permission. The Contacts framework would put a second consent prompt in
/// front of a feature the user already granted Full Disk Access for, so this reads the same SQLite
/// files the Contacts app writes — `~/Library/Application Support/AddressBook/AddressBook-v22.abcddb`
/// plus one per account under `Sources/<uuid>/`. Those live inside the Full Disk Access boundary, so
/// with FDA this works and without it the read simply fails and every handle stays a raw number.
final class ContactResolver: @unchecked Sendable {
    static let shared = ContactResolver()
    private let lock = NSLock()
    private var byPhone: [String: String] = [:]
    private var byEmail: [String: String] = [:]
    private var loaded = false

    static let root = Paths.home.appendingPathComponent("Library/Application Support/AddressBook")

    static func normalizePhone(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    /// Every AddressBook database on this Mac: the top-level one and one per configured account.
    static func databasePaths() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let top = root.appendingPathComponent("AddressBook-v22.abcddb").path
        if fm.isReadableFile(atPath: top) { out.append(top) }
        let sources = root.appendingPathComponent("Sources")
        for dir in (try? fm.contentsOfDirectory(atPath: sources.path))?.sorted() ?? [] {
            let p = sources.appendingPathComponent(dir).appendingPathComponent("AddressBook-v22.abcddb").path
            if fm.isReadableFile(atPath: p) { out.append(p) }
        }
        return out
    }

    func ensureLoaded() async {
        if lock.withLock({ loaded }) { return }
        await Task.detached(priority: .userInitiated) { [self] in self.load() }.value
    }

    private func load() {
        var phones: [String: String] = [:], emails: [String: String] = [:]
        var cards = Set<Int64>()
        var read = 0
        let paths = Self.databasePaths()
        for path in paths {
            do {
                let db = try Self.open(path)
                // ZABCDRECORD holds one row per card; phone numbers and email addresses live in
                // separate tables whose ZOWNER points back at it. One join per table rather than
                // both at once: joining both multiplies the rows (a card with 3 numbers and 2
                // addresses returns 6). ORDER BY the primary keys so a card with several numbers
                // always resolves to the same name.
                for row in try db.query("""
                    SELECT r.Z_PK AS pk, r.ZFIRSTNAME AS first, r.ZLASTNAME AS last,
                           r.ZNICKNAME AS nick, r.ZORGANIZATION AS org, p.ZFULLNUMBER AS phone
                    FROM ZABCDRECORD r
                    JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
                    WHERE p.ZFULLNUMBER IS NOT NULL
                    ORDER BY r.Z_PK, p.Z_PK
                    """) {
                    guard let name = Self.cardName(from: row), let raw = row.str("phone") else { continue }
                    if let pk = row.int64("pk") { cards.insert(pk) }
                    let k = Self.normalizePhone(raw)
                    if !k.isEmpty, phones[k] == nil { phones[k] = name }
                }
                for row in try db.query("""
                    SELECT r.Z_PK AS pk, r.ZFIRSTNAME AS first, r.ZLASTNAME AS last,
                           r.ZNICKNAME AS nick, r.ZORGANIZATION AS org, e.ZADDRESS AS email
                    FROM ZABCDRECORD r
                    JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
                    WHERE e.ZADDRESS IS NOT NULL
                    ORDER BY r.Z_PK, e.Z_PK
                    """) {
                    guard let name = Self.cardName(from: row), let addr = row.str("email")?.lowercased() else { continue }
                    if let pk = row.int64("pk") { cards.insert(pk) }
                    if emails[addr] == nil { emails[addr] = name }
                }
                read += 1
            } catch {
                Log.warn("AddressBook unreadable at \(path): \(error)")
            }
        }
        // Only a database that was actually read counts as loaded. Marking the cache loaded after a
        // failed read would freeze every handle at its raw number for the rest of the session, so a
        // Full Disk Access grant made a minute later would do nothing until a relaunch. Leaving
        // `loaded` false costs one cheap directory scan per lookup and picks the grant up at once.
        guard read > 0 else {
            Log.warn("ContactResolver read no AddressBook database (Full Disk Access?); will retry")
            return
        }
        lock.withLock { byPhone = phones; byEmail = emails; loaded = true }
        Log.info("ContactResolver loaded \(cards.count) cards from \(read) database(s) (\(phones.count) phones, \(emails.count) emails)")
    }

    /// Display name for a card row: full name, else nickname, else organization.
    private static func cardName(from row: [String: Any]) -> String? {
        let full = [row.str("first"), row.str("last")].compactMap { $0 }.joined(separator: " ")
        return [full, row.str("nick"), row.str("org")].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Read-only first so a live Contacts app's WAL is visible; immutable as a fallback when it is locked.
    private static func open(_ path: String) throws -> SQLiteDB {
        do {
            let db = try SQLiteDB(path: path, readOnly: true)
            _ = try db.scalar("SELECT 1 FROM ZABCDRECORD LIMIT 1")
            return db
        } catch {
            let db = try SQLiteDB(path: path, readOnly: true, immutable: true)
            _ = try db.scalar("SELECT 1 FROM ZABCDRECORD LIMIT 1")
            return db
        }
    }

    /// Contact name for a handle, or nil when unknown.
    func name(for handle: String) -> String? {
        lock.withLock {
            let h = handle.trimmingCharacters(in: .whitespaces)
            if h.contains("@") { return byEmail[h.lowercased()] }
            let k = Self.normalizePhone(h)
            return k.isEmpty ? nil : byPhone[k]
        }
    }

    /// Name if known, else the handle itself.
    func display(_ handle: String) -> String { name(for: handle) ?? handle }
}

// MARK: - chat.db access

enum MessagesError: Error, CustomStringConvertible {
    case noAccess(String)
    case notFound(String)
    var description: String {
        switch self {
        case .noAccess(let s): return s
        case .notFound(let s): return s
        }
    }
}

/// Read-only access to ~/Library/Messages/chat.db.
final class MessagesStore: @unchecked Sendable {
    static let shared = MessagesStore()
    static let dbPath = Paths.home.appendingPathComponent("Library/Messages/chat.db").path
    static let fdaGuidance = "Grant Avo Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then ask again."
    static let icon = "app:com.apple.MobileSMS"

    struct Chat {
        var rowId: Int64
        var guid: String
        var identifier: String
        var name: String
        var participants: [String]
        var isGroup: Bool
        var lastText: String
        var lastDate: Date?
        var lastFromMe: Bool
        var lastSender: String?
    }

    struct Message {
        var rowId: Int64
        var text: String
        var fromMe: Bool
        var sender: String
        var senderName: String
        var date: Date
        var isRead: Bool
        var hasAttachments: Bool
        var chatGuid: String?
        var chatName: String?
    }

    /// Whether chat.db is readable at all.
    ///
    /// Before the user grants Full Disk Access every read here is bound to fail, and that is an
    /// expected state on a fresh install, not an error. It is noted once per process and every
    /// caller after that backs off silently, so a missing grant costs one INFO line per launch
    /// rather than one error line per poll.
    static func accessGranted() -> Bool {
        if Permissions.fullDiskAccess { return true }
        waitingLock.withLock {
            guard !waitingLogged else { return }
            waitingLogged = true
            Log.info("iMessage: waiting for Full Disk Access")
        }
        return false
    }

    private static let waitingLock = NSLock()
    nonisolated(unsafe) private static var waitingLogged = false

    func open() throws -> SQLiteDB {
        guard Self.accessGranted() else {
            throw MessagesError.noAccess("Avo can't read Messages (chat.db). \(Self.fdaGuidance)")
        }
        let path = Self.dbPath
        var db: SQLiteDB
        do {
            db = try SQLiteDB(path: path, readOnly: true)
            _ = try db.scalar("SELECT 1 FROM chat LIMIT 1")
            return db
        } catch {
            Log.warn("chat.db read-only open failed (\(error)); retrying immutable")
        }
        do {
            db = try SQLiteDB(path: path, readOnly: true, immutable: true)
            _ = try db.scalar("SELECT 1 FROM chat LIMIT 1")
            return db
        } catch {
            Log.error("chat.db unreadable: \(error)")
            throw MessagesError.noAccess("Avo can't read Messages (chat.db). \(Self.fdaGuidance)")
        }
    }

    // MARK: decoding

    static func date(_ v: Any?) -> Date? {
        let raw: Double
        if let n = v as? Int64 { raw = Double(n) } else if let d = v as? Double { raw = d } else { return nil }
        guard raw > 0 else { return nil }
        let secs = raw > 1e11 ? raw / 1e9 : raw
        return Date(timeIntervalSinceReferenceDate: secs)
    }

    /// Best-effort extraction of the NSString payload from a typedstream `attributedBody` blob.
    static func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count + 4 else { return nil }
        var start: Int?
        var i = 0
        while i + marker.count <= bytes.count {
            if bytes[i] == marker[0], Array(bytes[i..<i + marker.count]) == marker { start = i + marker.count; break }
            i += 1
        }
        guard var p = start else { return nil }
        // Skip class-info bytes until the '+' (0x2B) that precedes the length.
        let limit = min(bytes.count, p + 24)
        while p < limit && bytes[p] != 0x2B { p += 1 }
        guard p < bytes.count, bytes[p] == 0x2B else { return nil }
        p += 1
        guard p < bytes.count else { return nil }
        var len = Int(bytes[p]); p += 1
        if len == 0x81 {
            guard p + 1 < bytes.count else { return nil }
            len = Int(bytes[p]) | (Int(bytes[p + 1]) << 8); p += 2
        } else if len == 0x82 {
            guard p + 3 < bytes.count else { return nil }
            len = Int(bytes[p]) | (Int(bytes[p + 1]) << 8) | (Int(bytes[p + 2]) << 16) | (Int(bytes[p + 3]) << 24); p += 4
        }
        guard len > 0, p + len <= bytes.count else { return nil }
        let slice = bytes[p..<p + len]
        return String(bytes: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
    }

    static func text(of row: [String: Any]) -> String {
        var t = row.str("text") ?? ""
        if t.isEmpty, let blob = row.data("attributedBody"), let s = decodeAttributedBody(blob) { t = s }
        t = t.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty, (row.int64("cache_has_attachments") ?? 0) != 0 { t = "[Attachment]" }
        return t
    }

    private func chatName(displayName: String?, identifier: String, style: Int64, participants: [String]) -> String {
        if let d = displayName?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        let r = ContactResolver.shared
        if style == 43 || participants.count > 1 {
            let names = participants.map { r.display($0) }
            return names.isEmpty ? identifier : names.joined(separator: ", ")
        }
        return r.display(identifier)
    }

    private func participants(_ db: SQLiteDB, chatId: Int64) throws -> [String] {
        try db.query("SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = ?", [chatId])
            .compactMap { $0.str("id") }
    }

    // MARK: queries

    func recentChats(limit: Int) throws -> [Chat] {
        let db = try open()
        let rows = try db.query("""
            SELECT c.ROWID AS chat_id, c.guid, c.chat_identifier, c.display_name, c.style,
                   m.text, m.attributedBody, m.is_from_me, m.date, m.cache_has_attachments, h.id AS sender
            FROM chat c
            JOIN message m ON m.ROWID = (
                SELECT cmj.message_id FROM chat_message_join cmj JOIN message mm ON mm.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID ORDER BY mm.date DESC LIMIT 1)
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            ORDER BY m.date DESC LIMIT ?
            """, [limit])
        return try rows.map { r in
            let id = r.int64("chat_id") ?? 0
            let parts = try participants(db, chatId: id)
            let ident = r.str("chat_identifier") ?? ""
            let style = r.int64("style") ?? 45
            return Chat(rowId: id, guid: r.str("guid") ?? "", identifier: ident,
                        name: chatName(displayName: r.str("display_name"), identifier: ident, style: style, participants: parts),
                        participants: parts, isGroup: style == 43 || parts.count > 1,
                        lastText: Self.text(of: r), lastDate: Self.date(r["date"]),
                        lastFromMe: (r.int64("is_from_me") ?? 0) == 1, lastSender: r.str("sender"))
        }
    }

    /// Find a chat by guid, or by a recipient handle/name.
    func findChat(guid: String?, recipient: String?) throws -> Chat? {
        let db = try open()
        func build(_ r: [String: Any]) throws -> Chat {
            let id = r.int64("chat_id") ?? r.int64("ROWID") ?? 0
            let parts = try participants(db, chatId: id)
            let ident = r.str("chat_identifier") ?? ""
            let style = r.int64("style") ?? 45
            return Chat(rowId: id, guid: r.str("guid") ?? "", identifier: ident,
                        name: chatName(displayName: r.str("display_name"), identifier: ident, style: style, participants: parts),
                        participants: parts, isGroup: style == 43 || parts.count > 1, lastText: "", lastDate: nil, lastFromMe: false, lastSender: nil)
        }
        if let g = guid?.trimmingCharacters(in: .whitespaces), !g.isEmpty {
            if let r = try db.query("SELECT ROWID AS chat_id, guid, chat_identifier, display_name, style FROM chat WHERE guid = ? LIMIT 1", [g]).first {
                return try build(r)
            }
        }
        guard let rec = recipient?.trimmingCharacters(in: .whitespaces), !rec.isEmpty else { return nil }
        if let r = try db.query("SELECT ROWID AS chat_id, guid, chat_identifier, display_name, style FROM chat WHERE chat_identifier = ? COLLATE NOCASE ORDER BY ROWID DESC LIMIT 1", [rec]).first {
            return try build(r)
        }
        // Normalised phone match, then contact-name match against recent chats.
        let norm = ContactResolver.normalizePhone(rec)
        let all = try db.query("""
            SELECT c.ROWID AS chat_id, c.guid, c.chat_identifier, c.display_name, c.style,
                   (SELECT MAX(mm.date) FROM chat_message_join cmj JOIN message mm ON mm.ROWID = cmj.message_id WHERE cmj.chat_id = c.ROWID) AS last_date
            FROM chat c ORDER BY last_date DESC LIMIT 200
            """)
        if norm.count >= 7 {
            if let r = all.first(where: { ContactResolver.normalizePhone($0.str("chat_identifier") ?? "") == norm && ($0.int64("style") ?? 45) == 45 }) {
                return try build(r)
            }
        }
        let want = rec.lowercased()
        for r in all {
            let c = try build(r)
            if c.name.lowercased() == want { return c }
        }
        for r in all {
            let c = try build(r)
            if !c.isGroup, c.name.lowercased().contains(want) { return c }
        }
        return nil
    }

    func messages(chatId: Int64, limit: Int) throws -> [Message] {
        let db = try open()
        let rows = try db.query("""
            SELECT m.ROWID AS msg_id, m.text, m.attributedBody, m.is_from_me, m.date, m.is_read, m.cache_has_attachments, h.id AS sender
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ? AND m.item_type = 0
            ORDER BY m.date DESC LIMIT ?
            """, [chatId, limit])
        return rows.map(message(from:)).reversed()
    }

    func search(_ query: String, limit: Int) throws -> [Message] {
        let db = try open()
        let esc = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let variants = Array(Set([query, query.lowercased(), query.capitalized, query.uppercased()]))
        var clauses = ["m.text LIKE ? ESCAPE '\\'"]
        var binds: [Any?] = ["%\(esc)%"]
        for v in variants { clauses.append("instr(m.attributedBody, ?) > 0"); binds.append(Data(v.utf8)) }
        binds.append(limit)
        let rows = try db.query("""
            SELECT m.ROWID AS msg_id, m.text, m.attributedBody, m.is_from_me, m.date, m.is_read, m.cache_has_attachments, h.id AS sender,
                   c.ROWID AS chat_id, c.guid AS chat_guid, c.chat_identifier, c.display_name, c.style
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.item_type = 0 AND (\(clauses.joined(separator: " OR ")))
            ORDER BY m.date DESC LIMIT ?
            """, binds)
        return try rows.compactMap { r in
            let text = Self.text(of: r)
            guard text.range(of: query, options: .caseInsensitive) != nil else { return nil }
            return try withChat(message(from: r), r, db)
        }
    }

    func unread(limit: Int) throws -> [Message] {
        let db = try open()
        let rows = try db.query("""
            SELECT m.ROWID AS msg_id, m.text, m.attributedBody, m.is_from_me, m.date, m.is_read, m.cache_has_attachments, h.id AS sender,
                   c.ROWID AS chat_id, c.guid AS chat_guid, c.chat_identifier, c.display_name, c.style
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0
            ORDER BY m.date DESC LIMIT ?
            """, [limit])
        return try rows.map { try withChat(message(from: $0), $0, db) }
    }

    private func message(from r: [String: Any]) -> Message {
        let sender = r.str("sender") ?? ""
        let fromMe = (r.int64("is_from_me") ?? 0) == 1
        return Message(rowId: r.int64("msg_id") ?? 0, text: Self.text(of: r), fromMe: fromMe,
                       sender: fromMe ? "me" : sender, senderName: fromMe ? "Me" : ContactResolver.shared.display(sender),
                       date: Self.date(r["date"]) ?? .distantPast, isRead: (r.int64("is_read") ?? 1) == 1,
                       hasAttachments: (r.int64("cache_has_attachments") ?? 0) != 0, chatGuid: nil, chatName: nil)
    }

    private func withChat(_ m: Message, _ r: [String: Any], _ db: SQLiteDB) throws -> Message {
        var m = m
        let id = r.int64("chat_id") ?? 0
        let parts = try participants(db, chatId: id)
        let ident = r.str("chat_identifier") ?? ""
        m.chatGuid = r.str("chat_guid")
        m.chatName = chatName(displayName: r.str("display_name"), identifier: ident, style: r.int64("style") ?? 45, participants: parts)
        return m
    }

    // MARK: sending

    func send(_ text: String, chatGuid: String?, recipient: String?) async throws {
        let msg = AppleScript.quote(text)
        let script: String
        if let g = chatGuid, !g.isEmpty {
            script = "tell application \"Messages\" to send \(msg) to chat id \(AppleScript.quote(g))"
        } else if let r = recipient, !r.isEmpty {
            script = """
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant \(AppleScript.quote(r)) of targetService
                send \(msg) to targetBuddy
            end tell
            """
        } else {
            throw MessagesError.notFound("No chat_guid or recipient")
        }
        Log.info("iMessage send → \(chatGuid ?? recipient ?? "?") (\(text.count) chars)")
        _ = try await AppleScript.run(script, timeout: 25)
    }
}

// MARK: - Tools

enum IMessageTools {
    static let group = "iMessage"
    static let icon = MessagesStore.icon

    static func all() -> [Tool] {
        [ListRecentChats(), ReadChatMessages(), SearchMessages(), GetUnreadMessages(), SendMessage()]
    }

    static func accessFailure(_ e: Error) -> ToolResult {
        let msg = "\(e)"
        var r = ToolResult.fail(msg, guidance: MessagesStore.fdaGuidance)
        r.cards = [Cards.note(source: "iMessage", icon: icon, title: "Messages needs Full Disk Access",
                              body: "System Settings → Privacy & Security → Full Disk Access → enable Avo, then ask again.")]
        return r
    }

    /// Full Disk Access is asked for here, the first time a tool actually reads chat.db, instead of
    /// during onboarding. Returns nil when the tool may proceed.
    static func gate() async -> ToolResult? {
        await PermissionGate.ensure(.fullDiskAccess) ? nil : PermissionGate.failure(.fullDiskAccess)
    }

    static func messageJSON(_ m: MessagesStore.Message) -> [String: Any] {
        var j: [String: Any] = ["from": m.senderName, "text": m.text, "sent": HDate.human(m.date), "from_me": m.fromMe]
        if !m.fromMe, m.sender != m.senderName { j["handle"] = m.sender }
        if let g = m.chatGuid { j["chat_guid"] = g }
        if let n = m.chatName { j["chat"] = n }
        if m.hasAttachments { j["has_attachment"] = true }
        return j
    }

    struct ListRecentChats: Tool {
        let name = "list_recent_chats"
        let description = "Pulls the threads the Messages app has seen most recently, iMessage and SMS alike, with the latest activity on top. For each thread you get its chat_guid, the name it shows under, who is in it, and a glimpse of the last thing said. Start here whenever you need to identify which conversation to read from or answer in."
        let params = [ToolParam("limit", "integer", "How many conversations to return (default 15, max 40).")]
        let statusLabel = "Reading chats"
        let statusIcon = IMessageTools.icon
        let group = IMessageTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let limit = min(max(args.int("limit") ?? 15, 1), 40)
            if let denied = await IMessageTools.gate() { return denied }
            await ContactResolver.shared.ensureLoaded()
            do {
                let chats = try MessagesStore.shared.recentChats(limit: limit)
                Log.info("iMessage list_recent_chats → \(chats.count)")
                let json: [[String: Any]] = chats.map { c in
                    var j: [String: Any] = ["chat_guid": c.guid, "name": c.name, "group": c.isGroup,
                                            "participants": c.participants.map { ContactResolver.shared.display($0) },
                                            "last_message": c.lastText.preview(140), "last_from_me": c.lastFromMe]
                    if let d = c.lastDate { j["last_at"] = HDate.human(d) }
                    return j
                }
                let rows = chats.prefix(6).map { c in
                    GlanceCard.Row(title: c.name, subtitle: (c.lastFromMe ? "You: " : "") + c.lastText.preview(70),
                                   icon: IMessageTools.icon, trailing: c.lastDate.map(HDate.relative), avatar: c.name)
                }
                return .ok(["ok": true, "chats": json], cards: [Cards.glance(source: "Messages", icon: IMessageTools.icon, rows: rows)])
            } catch { return IMessageTools.accessFailure(error) }
        }
    }

    struct ReadChatMessages: Tool {
        let name = "read_chat_messages"
        let description = "Returns the latest stretch of one conversation, oldest of that stretch first so it reads in order. Identify the thread with its chat_guid, which list_recent_chats supplies, or failing that with a phone number or email address. Every line comes back with its sender, its text, and its timestamp."
        let params = [
            ToolParam("chat_guid", "string", "Identifies the thread by the chat_guid that list_recent_chats returns — the preferred route. A phone number or email address in `recipient` is the alternative."),
            ToolParam("recipient", "string", "The other party's phone number or email address; consulted only when no chat_guid was supplied."),
            ToolParam("limit", "integer", "How many messages to return (default 25, max 100)."),
        ]
        let statusLabel = "Reading messages"
        let statusIcon = IMessageTools.icon
        let group = IMessageTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let limit = min(max(args.int("limit") ?? 25, 1), 100)
            if let denied = await IMessageTools.gate() { return denied }
            await ContactResolver.shared.ensureLoaded()
            do {
                guard let chat = try MessagesStore.shared.findChat(guid: args.str("chat_guid"), recipient: args.str("recipient")) else {
                    return .fail("No conversation matched.", guidance: "Call list_recent_chats and use the exact chat_guid.")
                }
                let msgs = try MessagesStore.shared.messages(chatId: chat.rowId, limit: limit)
                Log.info("iMessage read_chat_messages \(chat.name) → \(msgs.count)")
                let rows = msgs.suffix(6).map { m in
                    GlanceCard.Row(title: m.senderName, subtitle: m.text.preview(80), icon: m.fromMe ? "arrow.up.right" : IMessageTools.icon, trailing: HDate.relative(m.date))
                }
                return .ok(["ok": true, "chat_guid": chat.guid, "chat": chat.name, "group": chat.isGroup,
                            "messages": msgs.map(IMessageTools.messageJSON)],
                           cards: [Cards.glance(source: "Messages", icon: IMessageTools.icon, header: (chat.name, chat.isGroup ? "\(chat.participants.count) people" : nil), rows: rows)])
            } catch { return IMessageTools.accessFailure(error) }
        }
    }

    struct SearchMessages: Tool {
        let name = "search_messages"
        let description = "Looks through the user's recent message history for a phrase and hands back every line that contains it, each tagged with its thread, its sender, a snippet, and when it landed. Reach for it on questions like 'find the address Alex texted me' or 'what did Mom say about dinner?'."
        let params = [
            ToolParam("query", "string", "The phrase to look for in message text.", required: true),
            ToolParam("limit", "integer", "How many matches to return (default 20, max 50)."),
        ]
        let statusLabel = "Searching messages"
        let statusIcon = IMessageTools.icon
        let group = IMessageTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let q = args.str("query") else { return .fail("query is required") }
            let limit = min(max(args.int("limit") ?? 20, 1), 50)
            if let denied = await IMessageTools.gate() { return denied }
            await ContactResolver.shared.ensureLoaded()
            do {
                let msgs = try MessagesStore.shared.search(q, limit: limit)
                Log.info("iMessage search '\(q)' → \(msgs.count)")
                let rows = msgs.prefix(6).map { m in
                    GlanceCard.Row(title: "\(m.senderName)\(m.chatName.map { " · \($0)" } ?? "")", subtitle: m.text.preview(80), icon: IMessageTools.icon, trailing: HDate.relative(m.date))
                }
                return .ok(["ok": true, "query": q, "count": msgs.count, "matches": msgs.map(IMessageTools.messageJSON)],
                           cards: msgs.isEmpty ? [] : [Cards.glance(source: "Messages", icon: IMessageTools.icon, header: ("\"\(q)\"", "\(msgs.count) match\(msgs.count == 1 ? "" : "es")"), rows: rows)])
            } catch { return IMessageTools.accessFailure(error) }
        }
    }

    struct GetUnreadMessages: Tool {
        let name = "get_unread_messages"
        let description = "Returns messages other people have sent that the user has not opened yet, most recent first. Each one carries who sent it, the text, its arrival time, and the thread's chat_guid so a reply can go straight back. This answers 'do I have any new messages?' and 'summarize my unread texts'."
        let params = [ToolParam("limit", "integer", "How many unread messages to return (default 25, max 100).")]
        let statusLabel = "Checking unread"
        let statusIcon = IMessageTools.icon
        let group = IMessageTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let limit = min(max(args.int("limit") ?? 25, 1), 100)
            if let denied = await IMessageTools.gate() { return denied }
            await ContactResolver.shared.ensureLoaded()
            do {
                let msgs = try MessagesStore.shared.unread(limit: limit)
                Log.info("iMessage unread → \(msgs.count)")
                let rows = msgs.prefix(6).map { m in
                    GlanceCard.Row(title: m.chatName ?? m.senderName, subtitle: m.text.preview(80), icon: IMessageTools.icon, trailing: HDate.relative(m.date), tone: .accent)
                }
                let card = msgs.isEmpty
                    ? Cards.note(source: "Messages", icon: IMessageTools.icon, title: "No unread messages", body: "You're caught up.")
                    : Cards.glance(source: "Messages", icon: IMessageTools.icon, header: ("Unread", "\(msgs.count) message\(msgs.count == 1 ? "" : "s")"), rows: rows)
                return .ok(["ok": true, "count": msgs.count, "messages": msgs.map(IMessageTools.messageJSON)], cards: [card])
            } catch { return IMessageTools.accessFailure(error) }
        }
    }

    struct SendMessage: Tool {
        let name = "send_message"
        let description = "Sends a message through Messages. The overwhelmingly common case is answering inside a thread that already exists, so supply that thread's chat_guid — list_recent_chats, get_unread_messages and search_messages all return one. It covers group chats as well and pins the message to exactly the right thread. `recipient`, a phone number or email address, is reserved for opening a conversation that does not exist yet, and only when the user has actually spoken the number or address. Where the thread or the handle is at all uncertain, DO NOT guess — ask the user first. ALWAYS fill `to` as well: the readable name of the person or group, which is what the confirmation card displays."
        let params = [
            ToolParam("chat_guid", "string", "Which thread the message joins, taken from list_recent_chats, get_unread_messages or search_messages. Sending this way is the safe default because it addresses one exact thread, and group chats accept nothing else."),
            ToolParam("recipient", "string", "Reserved for opening a conversation that does not exist yet, and only where the user themselves supplied the phone number or email. A chat_guid overrides it. Numbers are never to be guessed or fabricated."),
            ToolParam("to", "string", "Name of the person or group as the user said it (e.g. 'Mom', 'Kai', 'TJ'). Avo resolves it to the right conversation. Shown on the confirmation card.", required: true),
            ToolParam("message", "string", "The full message text to send, written in the user's voice.", required: true),
        ]
        let statusLabel = "Sending"
        let statusIcon = IMessageTools.icon
        let group = IMessageTools.group
        var confirmation: ConfirmationSpec? {
            ConfirmationSpec(icon: IMessageTools.icon, title: "Send iMessage",
                             subtitle: { a in (a.str("to") ?? a.str("recipient")).map { "to \($0)" } },
                             fields: [(key: "to", label: "To", kind: .text, required: false),
                                      (key: "message", label: "Message", kind: .multiline, required: true),
                                      (key: "chat_guid", label: "Chat", kind: .text, required: false),
                                      (key: "recipient", label: "Recipient", kind: .text, required: false)],
                             confirmLabel: "Send", layout: .message)
        }
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let text = args.str("message") else { return .fail("message is empty") }
            var guid = args.str("chat_guid")
            let recipient = args.str("recipient")
            var label = args.str("to") ?? recipient ?? guid ?? "?"
            await ContactResolver.shared.ensureLoaded()
            // Resolve the thread through chat.db when readable; otherwise trust the guid/recipient as given.
            let lookup = guid == nil ? ((recipient?.isEmpty == false) ? recipient : args.str("to")) : nil
            if let chat = try? MessagesStore.shared.findChat(guid: guid, recipient: lookup) {
                guid = chat.guid; label = chat.name
            } else if guid == nil, let r = recipient, r.contains("@") || ContactResolver.normalizePhone(r).count >= 7 {
                // fresh conversation to a literal handle
            } else if guid == nil {
                let name = (args.str("to") ?? "").lowercased()
                let cands = ((try? MessagesStore.shared.recentChats(limit: 40)) ?? []).filter { !name.isEmpty && ($0.name.lowercased().contains(name) || name.contains($0.name.lowercased())) }.prefix(5)
                return .fail("Could not resolve '\(args.str("to") ?? "")' to a conversation.", guidance: cands.isEmpty ? "Ask the user for the person's number or exact name, or call list_recent_chats." : "Candidates: " + cands.map { "\($0.name) (chat_guid \($0.guid))" }.joined(separator: "; ") + ". Ask the user which one, then send with that chat_guid.")
            }
            do {
                try await MessagesStore.shared.send(text, chatGuid: guid, recipient: recipient)
                let sentGuid = guid ?? ""
                let sentLabel = label
                let sentRecipient = recipient
                await MainActor.run { ReplyWatch.shared.noteSent(kind: .imessage(chatGuid: sentGuid), label: sentLabel, fallbackHandle: sentRecipient) }
                return .ok(["ok": true, "sent_to": label, "chat_guid": guid ?? "", "message": text],
                           cards: [Cards.glance(source: "Messages", icon: IMessageTools.icon, header: ("Sent to \(label)", text.preview(120)))],
                           narration: "Sent to \(label).")
            } catch {
                return .fail("Messages could not send: \(error)", guidance: "If macOS asked for Automation permission, tell the user to allow Avo to control Messages, then retry.")
            }
        }
    }
}

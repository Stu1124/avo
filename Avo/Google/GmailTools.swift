import Foundation
import AppKit

// MARK: - Gmail helpers

enum Gmail {
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    static let icon = "envelope.fill"
    static let group = "Gmail"
    static let source = "Gmail"

    struct Summary {
        var id: String; var threadId: String; var fromName: String; var fromAddress: String
        var subject: String; var date: Date; var snippet: String; var unread: Bool
        var json: [String: Any] {
            ["id": id, "thread_id": threadId, "from": fromName, "from_address": fromAddress, "subject": subject,
             "date": GoogleDates.human(date), "snippet": snippet, "unread": unread]
        }
        var row: GlanceCard.Row {
            .init(title: fromName.isEmpty ? fromAddress : fromName, subtitle: subject.isEmpty ? "(no subject)" : subject, icon: nil,
                  trailing: GoogleDates.relative(date), tone: unread ? .accent : .neutral,
                  url: "https://mail.google.com/mail/u/0/#all/\(id)", avatar: fromName.isEmpty ? fromAddress : fromName,
                  meta: snippet, unread: unread)
        }
    }

    /// Splits "Name <addr>" / "addr" into (name, address).
    static func parseAddress(_ raw: String) -> (name: String, address: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let addr = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            return (decodeHeader(name), addr)
        }
        return ("", s)
    }
    static func addresses(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { parseAddress(String($0)).address.lowercased() }.filter { !$0.isEmpty }
    }

    /// Decodes RFC 2047 encoded words (=?utf-8?B?...?= / ?Q?) in a header value.
    static func decodeHeader(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var out = s
        let re = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#)
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            var decoded: String?
            if enc == "B", let d = Data(base64Encoded: payload) { decoded = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) }
            else if enc == "Q" {
                var t = payload.replacingOccurrences(of: "_", with: " ")
                var data = Data()
                var idx = t.startIndex
                while idx < t.endIndex {
                    if t[idx] == "=", let e = t.index(idx, offsetBy: 3, limitedBy: t.endIndex), let b = UInt8(t[t.index(after: idx)..<e], radix: 16) { data.append(b); idx = e }
                    else { data.append(contentsOf: Array(String(t[idx]).utf8)); idx = t.index(after: idx) }
                }
                t = String(data: data, encoding: .utf8) ?? t
                decoded = t
            }
            result += decoded ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        out = result.replacingOccurrences(of: "?= =?", with: "?==?")
        return out
    }

    static func header(_ msg: [String: Any], _ name: String) -> String? {
        let headers = (msg["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        return headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String
    }
    static func date(_ msg: [String: Any]) -> Date {
        if let ms = msg["internalDate"] as? String, let n = Double(ms) { return Date(timeIntervalSince1970: n / 1000) }
        if let ms = msg["internalDate"] as? NSNumber { return Date(timeIntervalSince1970: ms.doubleValue / 1000) }
        return Date()
    }

    static func summary(_ msg: [String: Any]) -> Summary {
        let from = parseAddress(header(msg, "From") ?? "")
        let labels = msg["labelIds"] as? [String] ?? []
        return Summary(id: msg["id"] as? String ?? "", threadId: msg["threadId"] as? String ?? "",
                       fromName: from.name, fromAddress: from.address,
                       subject: decodeHeader(header(msg, "Subject") ?? ""), date: date(msg),
                       snippet: decodeEntities(msg["snippet"] as? String ?? ""), unread: labels.contains("UNREAD"))
    }

    /// Runs messages.list then fetches metadata for each id (concurrently).
    static func listSummaries(q: String, max: Int) async throws -> [Summary] {
        let list = try await GoogleAPI.json(.GET, "\(base)/messages", query: ["q": q, "maxResults": max])
        let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        if ids.isEmpty { return [] }
        return try await withThrowingTaskGroup(of: (Int, Summary).self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask {
                    let m = try await GoogleAPI.json(.GET, "\(base)/messages/\(id)", query: ["format": "metadata", "metadataHeaders": ["From", "Subject", "Date"]])
                    return (i, summary(m))
                }
            }
            var out: [(Int, Summary)] = []
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    static func card(_ rows: [Summary], title: String, subtitle: String?) -> CardKind {
        var blocks: [GlanceCard.Block] = [.header(title: title, subtitle: subtitle, icon: icon)]
        if rows.isEmpty { blocks.append(.text("No messages.")) } else { blocks.append(.list(rows: rows.prefix(6).map { $0.row })) }
        return .glance(GlanceCard(id: UUID(), blocks: blocks, source: source, sourceIcon: icon))
    }

    // MARK: body extraction

    static func bodyText(_ payload: [String: Any]) -> String {
        var plain: [String] = []; var html: [String] = []
        func walk(_ p: [String: Any]) {
            let mime = (p["mimeType"] as? String ?? "").lowercased()
            let filename = p["filename"] as? String ?? ""
            if let parts = p["parts"] as? [[String: Any]] { parts.forEach(walk) }
            guard filename.isEmpty, let data = (p["body"] as? [String: Any])?["data"] as? String, let d = Data(base64URL: data) else { return }
            let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
            if mime == "text/plain" { plain.append(text) } else if mime == "text/html" { html.append(text) }
        }
        walk(payload)
        if !plain.isEmpty { return plain.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        if !html.isEmpty { return stripHTML(html.joined(separator: "\n")) }
        return ""
    }

    static func attachments(_ payload: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ p: [String: Any]) {
            if let parts = p["parts"] as? [[String: Any]] { parts.forEach(walk) }
            if let f = p["filename"] as? String, !f.isEmpty {
                var a: [String: Any] = ["name": f, "mime_type": p["mimeType"] as? String ?? ""]
                if let size = (p["body"] as? [String: Any])?["size"] as? Int { a["size"] = size }
                out.append(a)
            }
        }
        walk(payload)
        return out
    }

    static func stripHTML(_ html: String) -> String {
        var s = html
        for pat in [#"(?is)<(script|style|head)[^>]*>.*?</\1>"#, #"(?i)<!--.*?-->"#] {
            s = s.replacingOccurrences(of: pat, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</(p|div|tr|li|h[1-6]|blockquote|table)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let map = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&#x27;": "'", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&copy;": "©", "&zwnj;": "", "&zwj;": ""]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        let re = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        let ns = out as NSString
        var result = ""; var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let v = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { result += String(Character(u)) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: MIME

    static func encodeHeaderValue(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    static func mime(from: String?, to: [String], cc: [String], subject: String, body: String, inReplyTo: String? = nil, references: String? = nil) -> String {
        var lines: [String] = []
        if let from, !from.isEmpty { lines.append("From: \(from)") }
        lines.append("To: \(to.joined(separator: ", "))")
        if !cc.isEmpty { lines.append("Cc: \(cc.joined(separator: ", "))") }
        lines.append("Subject: \(encodeHeaderValue(subject))")
        lines.append("Date: \(GoogleDates.rfc2822(Date()))")
        if let inReplyTo { lines.append("In-Reply-To: \(inReplyTo)") }
        if let references, !references.isEmpty { lines.append("References: \(references)") }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        let b64 = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + b64 + "\r\n"
    }

    static func send(raw: String, threadId: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["raw": Data(raw.utf8).base64URLEncoded()]
        if let threadId { body["threadId"] = threadId }
        return try await GoogleAPI.json(.POST, "\(base)/messages/send", jsonBody: body)
    }

    static func validEmails(_ list: [String]) -> [String]? {
        let ok = list.allSatisfy { parseAddress($0).address.range(of: #"^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$"#, options: .regularExpression) != nil }
        return ok ? list : nil
    }
}

// MARK: - Tools

struct GmailListUnread: Tool {
    let name = "gmail_list_unread"
    let description = "Returns whatever is sitting unread in the user's Gmail, most recent at the top, with the Promotions and Social tabs left out. Every entry carries the sender, the subject line, the date, a brief snippet, and an `id` that gmail_read_message, gmail_reply and gmail_archive all take. This is the tool behind questions like 'do I have new mail?', 'what's in my inbox?' and 'summarize my unread email'."
    let params = [
        ToolParam("max_results", "integer", "How many messages to return, 1–15. Default 10."),
        ToolParam("include_all", "boolean", "Set true to include Promotions and Social tab mail. Default false."),
    ]
    let statusLabel = "Checking Gmail"
    let statusIcon = Gmail.icon
    let group = Gmail.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            let max = GoogleAPI.int(args["max_results"], default: 10, max: 15)
            let q = GoogleAPI.bool(args["include_all"]) ? "is:unread" : "is:unread -category:promotions -category:social"
            let rows = try await Gmail.listSummaries(q: q, max: max)
            return .ok(["ok": true, "count": rows.count, "messages": rows.map { $0.json }],
                       cards: [Gmail.card(rows, title: "Unread", subtitle: rows.isEmpty ? "Inbox is clear" : "\(rows.count) unread")])
        }
    }
}

struct GmailSearch: Tool {
    let name = "gmail_search"
    let description = "Search the user's Gmail. Unlike Apple Mail, this DOES search full message bodies as well as subject, sender and attachments, using Gmail's own query syntax (e.g. 'from:maria has:attachment', 'invoice newer_than:30d', 'subject:\"offer letter\"'). Use the helper params for sender/subject/recency, or put everything in `query`. Returns an `id` per result for gmail_read_message, gmail_reply or gmail_archive. Use for 'find the email about the budget', 'emails from Stripe last week'."
    let params = [
        ToolParam("query", "string", "Gmail search text or query syntax. Plain words match anywhere in the message including the body. Keep it short and distinctive."),
        ToolParam("from", "string", "Narrows results to a particular sender, matched against either their display name or their address — 'Maria' and 'stripe.com' both work."),
        ToolParam("subject", "string", "Words that must appear in the subject line."),
        ToolParam("newer_than", "string", "Only mail newer than this, as Gmail relative syntax: '7d', '30d', '3m', '1y'."),
        ToolParam("unread_only", "boolean", "Only unread messages. Default false."),
        ToolParam("max_results", "integer", "How many results to return, 1–15. Default 10."),
    ]
    let statusLabel = "Searching Gmail"
    let statusIcon = Gmail.icon
    let group = Gmail.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            var parts: [String] = []
            if let q = GoogleAPI.trimmed(args["query"]) { parts.append(q) }
            if let f = GoogleAPI.trimmed(args["from"]) { parts.append("from:(\(f))") }
            if let s = GoogleAPI.trimmed(args["subject"]) { parts.append("subject:(\(s))") }
            if let n = GoogleAPI.trimmed(args["newer_than"]) { parts.append("newer_than:\(n)") }
            if GoogleAPI.bool(args["unread_only"]) { parts.append("is:unread") }
            guard !parts.isEmpty else { return .fail("Nothing to search for.", guidance: "Pass query, from, subject or newer_than.") }
            let q = parts.joined(separator: " ")
            let rows = try await Gmail.listSummaries(q: q, max: GoogleAPI.int(args["max_results"], default: 10, max: 15))
            return .ok(["ok": true, "query": q, "count": rows.count, "messages": rows.map { $0.json }],
                       cards: [Gmail.card(rows, title: "Mail search", subtitle: q)])
        }
    }
}

struct GmailReadMessage: Tool {
    let name = "gmail_read_message"
    let description = "Pulls a single Gmail message in its entirety — the body, all of its recipients, when it was sent, and what came attached. The `id` it needs comes from gmail_list_unread or gmail_search; ids must never be invented, and a subject line is not an id. For messages too long to return at once, walk through the body with `offset`."
    let params = [
        ToolParam("message_id", "string", "The message id from gmail_list_unread or gmail_search. Required.", required: true),
        ToolParam("offset", "integer", "Character offset into the body to start from, for long messages. Default 0."),
        ToolParam("max_chars", "integer", "Maximum body characters to return. Default 6000."),
        ToolParam("mark_read", "boolean", "Also mark the message as read. Default false."),
    ]
    let statusLabel = "Reading email"
    let statusIcon = Gmail.icon
    let group = Gmail.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let id = GoogleAPI.trimmed(args["message_id"]) else { return .fail("message_id is required.") }
            let m = try await GoogleAPI.json(.GET, "\(Gmail.base)/messages/\(id)", query: ["format": "full"])
            let payload = m["payload"] as? [String: Any] ?? [:]
            let s = Gmail.summary(m)
            let full = Gmail.bodyText(payload)
            let offset = Swift.max(0, GoogleAPI.int(args["offset"], default: 1) - 1)
            let maxChars = GoogleAPI.int(args["max_chars"], default: 6000, max: 40000)
            let start = min(offset, full.count)
            let slice = String(full.dropFirst(start).prefix(maxChars))
            let atts = Gmail.attachments(payload)
            if GoogleAPI.bool(args["mark_read"]) {
                _ = try? await GoogleAPI.json(.POST, "\(Gmail.base)/messages/\(id)/modify", jsonBody: ["removeLabelIds": ["UNREAD"]])
            }
            var j: [String: Any] = [
                "ok": true, "id": s.id, "thread_id": s.threadId, "from": s.fromName, "from_address": s.fromAddress,
                "to": Gmail.header(m, "To") ?? "", "cc": Gmail.header(m, "Cc") ?? "", "subject": s.subject,
                "date": GoogleDates.human(s.date, withYear: true), "body": slice, "body_length": full.count,
                "attachments": atts, "unread": s.unread,
            ]
            if start + slice.count < full.count { j["next_offset"] = start + slice.count; j["note"] = "Body truncated; call again with offset=\(start + slice.count) for more." }
            if full.isEmpty { j["note"] = "This message has no readable text body (it may be only attachments or images)." }
            let link = "https://mail.google.com/mail/u/0/#all/\(s.id)"
            let subject = s.subject
            let card = CardKind.glance(GlanceCard(id: UUID(), blocks: [
                .header(title: s.subject.isEmpty ? "(no subject)" : s.subject, subtitle: nil, icon: Gmail.icon),
                .email(from: s.fromName.isEmpty ? s.fromAddress : s.fromName, address: s.fromName.isEmpty ? "" : s.fromAddress,
                       date: GoogleDates.human(s.date), body: full.isEmpty ? "No text body." : String(full.prefix(4000)),
                       attachments: atts.compactMap { $0["name"] as? String }),
                .actions([
                    .init(label: "Reply", icon: "arrowshape.turn.up.left.fill", accent: true) {
                        Task { @MainActor in await AgentRuntime.shared.run(text: "Reply to the email \"\(subject)\" that you just showed me") }
                    },
                    .init(label: "Open in Gmail", icon: "arrow.up.right") { if let u = URL(string: link) { NSWorkspace.shared.open(u) } },
                ]),
            ], source: Gmail.source, sourceIcon: Gmail.icon))
            return .ok(j, cards: [card])
        }
    }
}

struct GmailSend: Tool {
    let name = "gmail_send"
    let description = "Composes and sends a brand-new email out of the user's Gmail account. Restrict it to messages that begin with the user; NEVER answer arriving mail with it. Any request phrased as reply, respond, answer, or get back to someone belongs to gmail_reply instead — and that stays true after gmail_reply has failed, where the fix is a fresh gmail_search for a current id followed by another gmail_reply, not a new message written here. Recipient addresses are never to be made up: ask when you are not sure where a message is going. The body is yours to write, in the user's voice, as plain text."
    let params = [
        ToolParam("to", "string", "Where the message goes: one address, or several joined by commas. Only genuine addresses belong here — ones the user stated, or ones returned by another Gmail tool.", required: true),
        ToolParam("cc", "string", "Optional Cc addresses, comma separated."),
        ToolParam("subject", "string", "Subject line.", required: true),
        ToolParam("body", "string", "Plain-text body, written in the user's voice.", required: true),
    ]
    let confirmation: ConfirmationSpec? = ConfirmationSpec(
        icon: Gmail.icon, title: "Send email",
        subtitle: { a in JSON.string(a["to"]).map { "to \($0)" } },
        fields: [("to", "To", .text, true), ("cc", "Cc", .text, false), ("subject", "Subject", .text, true), ("body", "Body", .multiline, true)],
        confirmLabel: "Send", layout: .email)
    let statusLabel = "Sending email"
    let statusIcon = "paperplane.fill"
    let group = Gmail.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            let to = GoogleAPI.strings(args["to"]); let cc = GoogleAPI.strings(args["cc"])
            guard !to.isEmpty else { return .fail("No recipient.", guidance: "Ask the user for the address.") }
            guard Gmail.validEmails(to + cc) != nil else { return .fail("A recipient address is not a valid email: \(to + cc)", guidance: "Confirm the exact address with the user.") }
            guard let subject = GoogleAPI.trimmed(args["subject"]) else { return .fail("subject is required.") }
            guard let body = GoogleAPI.trimmed(args["body"]) else { return .fail("body is required.") }
            let raw = Gmail.mime(from: await GoogleAuth.shared.email, to: to, cc: cc, subject: subject, body: body)
            let r = try await Gmail.send(raw: raw)
            if let tid = r["threadId"] as? String {
                let label = Gmail.parseAddress(to[0]).name.isEmpty ? to[0] : Gmail.parseAddress(to[0]).name
                await MainActor.run { ReplyWatch.shared.noteSent(kind: .gmail(threadId: tid), label: label) }
            }
            let card = CardKind.glance(GlanceCard(id: UUID(), blocks: [
                .header(title: "Sent", subtitle: subject, icon: "paperplane.fill"),
                .keyValue(pairs: [("To", to.joined(separator: ", "))] + (cc.isEmpty ? [] : [("Cc", cc.joined(separator: ", "))])),
            ], source: Gmail.source, sourceIcon: Gmail.icon))
            return .ok(["ok": true, "id": r["id"] as? String ?? "", "thread_id": r["threadId"] as? String ?? "", "to": to, "subject": subject], cards: [card])
        }
    }
}

struct GmailReply: Tool {
    let name = "gmail_reply"
    let description = "Answers a message that came in, staying inside its existing Gmail thread by setting the In-Reply-To and References headers; the earlier text is not quoted back. Give it the `id` produced by gmail_list_unread or gmail_search. Should it come back ok:false, run gmail_search once more for a live id and call THIS tool again — switching to gmail_send is the wrong move. The reply body is yours to write, in the user's voice and in whatever language the original used. Only set reply_all when the user says everyone should be included. Addressing comes from the original message, so `to` stays empty unless the user names a different recipient outright."
    let params = [
        ToolParam("message_id", "string", "The message id to reply to, from gmail_list_unread or gmail_search.", required: true),
        ToolParam("body", "string", "Plain-text reply body, written in the user's voice.", required: true),
        ToolParam("reply_all", "boolean", "When true, the answer goes to everyone on the original message instead of the sender alone. Off unless set."),
        ToolParam("to", "string", "Leave empty to reply to the original sender (Reply-To if set). Only set this when the user explicitly names a different recipient."),
    ]
    let confirmation: ConfirmationSpec? = ConfirmationSpec(
        icon: "arrowshape.turn.up.left.fill", title: "Send reply",
        subtitle: { a in GoogleAPI.bool(a["reply_all"]) ? "to everyone on the thread" : "to the original sender" },
        fields: [("to", "To (blank = original sender)", .text, false), ("body", "Reply", .multiline, true)],
        confirmLabel: "Send", layout: .reply)
    let statusLabel = "Sending reply"
    let statusIcon = "arrowshape.turn.up.left.fill"
    let group = Gmail.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let id = GoogleAPI.trimmed(args["message_id"]) else { return .fail("message_id is required.") }
            guard let body = GoogleAPI.trimmed(args["body"]) else { return .fail("body is required.") }
            let m = try await GoogleAPI.json(.GET, "\(Gmail.base)/messages/\(id)", query: ["format": "metadata", "metadataHeaders": ["From", "To", "Cc", "Subject", "Message-ID", "References", "Reply-To"]])
            guard let threadId = m["threadId"] as? String else { return .fail("Message \(id) not found.", guidance: "Call gmail_search for a fresh id and retry.") }
            let me = (await GoogleAuth.shared.email ?? "").lowercased()
            let fromAddr = Gmail.parseAddress(Gmail.header(m, "From") ?? "").address
            let replyTo = Gmail.header(m, "Reply-To").map { Gmail.parseAddress($0).address } ?? ""
            var to: [String]
            if let override = GoogleAPI.trimmed(args["to"]) { to = GoogleAPI.strings(override) }
            else { to = [replyTo.isEmpty ? fromAddr : replyTo] }
            var cc: [String] = []
            if GoogleAPI.bool(args["reply_all"]) {
                let others = (Gmail.addresses(Gmail.header(m, "To")) + Gmail.addresses(Gmail.header(m, "Cc")))
                    .filter { $0 != me && !to.map { $0.lowercased() }.contains($0) }
                cc = Array(NSOrderedSet(array: others)) as? [String] ?? others
            }
            to = to.filter { !$0.isEmpty }
            guard !to.isEmpty, Gmail.validEmails(to + cc) != nil else { return .fail("Could not determine a valid recipient for the reply.") }
            var subject = Gmail.decodeHeader(Gmail.header(m, "Subject") ?? "")
            if subject.range(of: #"^\s*re:"#, options: [.regularExpression, .caseInsensitive]) == nil { subject = "Re: \(subject)" }
            let msgId = Gmail.header(m, "Message-ID")
            let refs = [Gmail.header(m, "References"), msgId].compactMap { $0 }.joined(separator: " ")
            let raw = Gmail.mime(from: me.isEmpty ? nil : me, to: to, cc: cc, subject: subject, body: body, inReplyTo: msgId, references: refs)
            let r = try await Gmail.send(raw: raw, threadId: threadId)
            let fromName = Gmail.parseAddress(Gmail.header(m, "From") ?? "").name
            let watchLabel = fromName.isEmpty ? to[0] : fromName
            await MainActor.run { ReplyWatch.shared.noteSent(kind: .gmail(threadId: threadId), label: watchLabel) }
            let card = CardKind.glance(GlanceCard(id: UUID(), blocks: [
                .header(title: "Replied", subtitle: subject, icon: "arrowshape.turn.up.left.fill"),
                .keyValue(pairs: [("To", to.joined(separator: ", "))] + (cc.isEmpty ? [] : [("Cc", cc.joined(separator: ", "))])),
            ], source: Gmail.source, sourceIcon: Gmail.icon))
            return .ok(["ok": true, "id": r["id"] as? String ?? "", "thread_id": threadId, "to": to, "cc": cc, "subject": subject], cards: [card])
        }
    }
}

struct GmailArchive: Tool {
    let name = "gmail_archive"
    let description = "Archive a Gmail message: removes it from the Inbox without deleting it, for inbox triage ('archive that', 'get it out of my inbox'). Takes the `id` from gmail_list_unread or gmail_search. Pass the subject and sender too so the confirmation identifies the message."
    let params = [
        ToolParam("message_id", "string", "The message id to archive, from gmail_list_unread or gmail_search.", required: true),
        ToolParam("subject", "string", "The message's subject, copied from the list result, so the confirmation can show it."),
        ToolParam("from", "string", "The sender, copied from the list result."),
    ]
    let confirmation: ConfirmationSpec? = ConfirmationSpec(
        icon: "archivebox.fill", title: "Archive email",
        subtitle: { a in JSON.string(a["from"]).map { "from \($0)" } },
        fields: [("subject", "Message", .text, false)],
        confirmLabel: "Archive", destructive: false)
    let statusLabel = "Archiving"
    let statusIcon = "archivebox.fill"
    let group = Gmail.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            guard let id = GoogleAPI.trimmed(args["message_id"]) else { return .fail("message_id is required.") }
            _ = try await GoogleAPI.json(.POST, "\(Gmail.base)/messages/\(id)/modify", jsonBody: ["removeLabelIds": ["INBOX"]])
            return .ok(["ok": true, "id": id, "archived": true])
        }
    }
}

struct GmailMarkRead: Tool {
    let name = "gmail_mark_read"
    let description = "Mark one or more Gmail messages as read (or unread). Takes ids from gmail_list_unread or gmail_search. Use for 'mark those as read' after summarizing the inbox, or 'mark it unread'."
    let params = [
        ToolParam("message_ids", "array", "Message ids to update, from gmail_list_unread or gmail_search.", required: true, items: "string"),
        ToolParam("read", "boolean", "true to mark read (default), false to mark unread."),
    ]
    let statusLabel = "Updating mail"
    let statusIcon = "envelope.open.fill"
    let group = Gmail.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        await GoogleAPI.gated {
            let ids = GoogleAPI.strings(args["message_ids"])
            guard !ids.isEmpty else { return .fail("message_ids is required.") }
            let read = args["read"] == nil ? true : GoogleAPI.bool(args["read"])
            let body: [String: Any] = read ? ["ids": ids, "removeLabelIds": ["UNREAD"]] : ["ids": ids, "addLabelIds": ["UNREAD"]]
            _ = try await GoogleAPI.request(.POST, "\(Gmail.base)/messages/batchModify", jsonBody: body)
            return .ok(["ok": true, "updated": ids.count, "read": read])
        }
    }
}

import Foundation

/// Thin HTTP layer over Google REST APIs with bearer auth, JSON helpers and readable errors.
enum GoogleAPI {
    enum Method: String { case GET, POST, PATCH, PUT, DELETE }

    struct APIError: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }
    }

    /// Body sent as-is with an explicit content type (multipart uploads, raw text).
    struct RawBody { var data: Data; var contentType: String }

    /// Performs an authenticated request. Query values may be String, numbers, Bool, or [String] (repeated keys).
    static func request(_ method: Method, _ url: String, query: [String: Any] = [:], jsonBody: Any? = nil, raw: RawBody? = nil) async throws -> (Data, HTTPURLResponse) {
        var token = try await GoogleAuth.shared.accessToken()
        var attempt = 0
        while true {
            attempt += 1
            let req = try build(method, url, query: query, jsonBody: jsonBody, raw: raw, token: token)
            let (data, resp): (Data, URLResponse)
            do { (data, resp) = try await URLSession.shared.data(for: req) }
            catch { throw APIError(status: 0, message: "Could not reach Google: \(error.localizedDescription)") }
            guard let http = resp as? HTTPURLResponse else { throw APIError(status: 0, message: "No HTTP response from Google.") }
            if http.statusCode == 401, attempt == 1 {
                token = try await GoogleAuth.shared.accessToken(forceRefresh: true)
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError(status: http.statusCode, message: errorText(from: data, status: http.statusCode))
            }
            return (data, http)
        }
    }

    static func json(_ method: Method, _ url: String, query: [String: Any] = [:], jsonBody: Any? = nil, raw: RawBody? = nil) async throws -> [String: Any] {
        let (data, _) = try await request(method, url, query: query, jsonBody: jsonBody, raw: raw)
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func build(_ method: Method, _ url: String, query: [String: Any], jsonBody: Any?, raw: RawBody?, token: String) throws -> URLRequest {
        guard var comps = URLComponents(string: url) else { throw APIError(status: 0, message: "Bad URL \(url)") }
        var items = comps.queryItems ?? []
        for (k, v) in query.sorted(by: { $0.key < $1.key }) {
            if let arr = v as? [String] { arr.forEach { items.append(.init(name: k, value: $0)) } }
            else if let b = v as? Bool { items.append(.init(name: k, value: b ? "true" : "false")) }
            else { items.append(.init(name: k, value: "\(v)")) }
        }
        if !items.isEmpty { comps.queryItems = items }
        // Google rejects unencoded '+' in some query values (e.g. timeMin offsets); encode it explicitly.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let u = comps.url else { throw APIError(status: 0, message: "Bad URL \(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = method.rawValue
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let raw {
            req.setValue(raw.contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = raw.data
        } else if let jsonBody {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        return req
    }

    /// Extracts the human message from a Google error body.
    static func errorText(from data: Data, status: Int) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let e = obj["error"] as? [String: Any] {
                let msg = (e["message"] as? String) ?? ""
                let reason = ((e["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (e["status"] as? String) ?? ""
                if !msg.isEmpty { return "Google error \(status)\(reason.isEmpty ? "" : " (\(reason))"): \(msg)" }
            }
            if let e = obj["error"] as? String {
                let d = obj["error_description"] as? String ?? ""
                return "Google error \(status): \(e)\(d.isEmpty ? "" : " — \(d)")"
            }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 403: return "Google error 403: permission denied. \(text.isEmpty ? "The account may lack access or the API is not enabled." : text)"
        case 404: return "Google error 404: not found. \(text)"
        case 429: return "Google error 429: rate limited. Try again in a moment."
        default: return "Google error \(status). \(text)"
        }
    }

    /// Runs a tool body behind the connection gate and turns thrown errors into readable failures.
    static func gated(_ body: () async throws -> ToolResult) async -> ToolResult {
        if let fail = await GoogleAuth.shared.requireToken() { return fail }
        do { return try await body() }
        catch let e as GoogleAuth.AuthError {
            let connected = await GoogleAuth.shared.isConnected
            return connected ? .fail(e.message) : ToolResult(json: ["ok": false, "error": e.message, "guidance": GoogleAuth.notConnectedGuidance], cards: [await GoogleAuth.shared.connectCard()], ok: false)
        }
        catch let e as APIError { return .fail(e.message, guidance: e.status == 404 ? "The id may be stale. Look it up again with a list/search tool and retry." : nil) }
        catch { return .fail(error.localizedDescription) }
    }

    static func int(_ v: Any?, default d: Int, max cap: Int? = nil) -> Int {
        var n = d
        if let i = v as? Int { n = i } else if let x = v as? Double { n = Int(x) } else if let s = v as? String, let i = Int(s) { n = i }
        if let cap { n = min(n, cap) }
        return Swift.max(n, 1)
    }
    static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return (s as NSString).boolValue }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }
    static func strings(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let a = v as? [Any] { return a.compactMap { JSON.string($0) }.filter { !$0.isEmpty } }
        if let s = v as? String { return s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return []
    }
    static func trimmed(_ v: Any?) -> String? {
        guard let s = JSON.string(v)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// Date parsing/formatting shared by the Google tools. Naive ISO strings are interpreted in the user's local time zone.
enum GoogleDates {
    static let tz = TimeZone.current
    static var tzId: String { tz.identifier }

    struct Parsed { var date: Date; var dateOnly: Bool }

    /// Accepts '2026-06-20', '2026-06-20T15:00', '2026-06-20T15:00:00', with optional seconds/fraction/offset/Z.
    static func parse(_ raw: String?) -> Parsed? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.contains(" ") && !s.contains("T") { s = s.replacingOccurrences(of: " ", with: "T") }
        let iso = ISO8601DateFormatter()
        iso.timeZone = tz
        if s.count == 10 {
            iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
            if let d = iso.date(from: s) { return Parsed(date: d, dateOnly: true) }
            return nil
        }
        let hasOffset = s.hasSuffix("Z") || s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if !hasOffset {
            if s.count == 16 { s += ":00" }   // HH:mm → HH:mm:ss
            let f = DateFormatter(); f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX")
            for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
                f.dateFormat = fmt
                if let d = f.date(from: s) { return Parsed(date: d, dateOnly: false) }
            }
            return nil
        }
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return Parsed(date: d, dateOnly: false) }
        }
        return nil
    }

    /// RFC 3339 with the local offset, for Google timeMin/timeMax and event dateTime fields.
    static func rfc3339(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = tz; f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
    static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    /// Parses a Google event start/end object ({dateTime} or {date}).
    static func fromEventTime(_ obj: [String: Any]?) -> Parsed? {
        guard let obj else { return nil }
        if let dt = obj["dateTime"] as? String { return parse(dt) }
        if let d = obj["date"] as? String { return parse(d) }
        return nil
    }

    static func human(_ d: Date, withYear: Bool = false) -> String {
        let f = DateFormatter(); f.timeZone = tz
        f.dateFormat = withYear ? "EEE MMM d, yyyy h:mm a" : "EEE MMM d, h:mm a"
        return f.string(from: d)
    }
    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
    static func dayShort(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "EEE d"
        return f.string(from: d)
    }
    /// "Thu 7:00–8:00 PM" / "Thu · all day"
    static func span(start: Parsed, end: Parsed?) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "EEE"
        let day = f.string(from: start.date)
        if start.dateOnly { return "\(day) · all day" }
        var s = "\(day) \(time(start.date))"
        if let end, !end.dateOnly { s += "–\(time(end.date))" }
        return s
    }
    static func relative(_ d: Date) -> String {
        let secs = Date().timeIntervalSince(d)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        if secs < 86400 * 7 { return "\(Int(secs / 86400))d" }
        let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "MMM d"
        return f.string(from: d)
    }
    static func rfc2822(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }
}

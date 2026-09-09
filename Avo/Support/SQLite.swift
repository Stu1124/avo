import Foundation
import SQLite3

/// Thin wrapper over the system libsqlite3: open, bind, step, rows as dictionaries.
final class SQLiteDB {
    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `immutable` opens via a `file:` URI with `?immutable=1` (no locking, ignores WAL). Prefer plain read-only first so WAL contents are visible.
    init(path: String, readOnly: Bool = true, immutable: Bool = false) throws {
        var flags: Int32 = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var name = path
        if immutable {
            flags |= SQLITE_OPEN_URI
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "?#%")
            name = "file:" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path) + "?immutable=1"
        }
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(name, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed (\(rc))"
            if let h { sqlite3_close(h) }
            throw Error(message: msg)
        }
        db = h
        sqlite3_busy_timeout(h, 1500)
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    private var errmsg: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    /// Run a query with positional `?` binds. Supports String, Int, Int64, Double, Bool, Data and nil.
    func query(_ sql: String, _ binds: [Any?] = []) throws -> [[String: Any]] {
        guard let db else { throw Error(message: "database closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error(message: errmsg) }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() { try bind(stmt, Int32(i + 1), b) }
        let n = sqlite3_column_count(stmt)
        let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row: [String: Any] = [:]
                for c in 0..<n { if let v = value(stmt, c) { row[names[Int(c)]] = v } }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw Error(message: errmsg)
            }
        }
        return rows
    }

    func scalar(_ sql: String, _ binds: [Any?] = []) throws -> Any? {
        try query(sql, binds).first?.values.first
    }

    private func bind(_ stmt: OpaquePointer, _ i: Int32, _ v: Any?) throws {
        let rc: Int32
        switch v {
        case nil: rc = sqlite3_bind_null(stmt, i)
        case let s as String: rc = sqlite3_bind_text(stmt, i, s, -1, Self.transient)
        case let d as Data: rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(d.count), Self.transient) }
        case let b as Bool: rc = sqlite3_bind_int64(stmt, i, b ? 1 : 0)
        case let n as Int: rc = sqlite3_bind_int64(stmt, i, Int64(n))
        case let n as Int64: rc = sqlite3_bind_int64(stmt, i, n)
        case let n as Double: rc = sqlite3_bind_double(stmt, i, n)
        case let n as NSNumber: rc = sqlite3_bind_double(stmt, i, n.doubleValue)
        default: throw Error(message: "unsupported bind type \(type(of: v!))")
        }
        if rc != SQLITE_OK { throw Error(message: errmsg) }
    }

    private func value(_ stmt: OpaquePointer, _ c: Int32) -> Any? {
        switch sqlite3_column_type(stmt, c) {
        case SQLITE_INTEGER: return sqlite3_column_int64(stmt, c)
        case SQLITE_FLOAT: return sqlite3_column_double(stmt, c)
        case SQLITE_TEXT:
            guard let t = sqlite3_column_text(stmt, c) else { return "" }
            return String(cString: t)
        case SQLITE_BLOB:
            guard let p = sqlite3_column_blob(stmt, c) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, c)))
        default: return nil
        }
    }
}

/// Typed accessors for tool argument dictionaries and SQLite rows.
extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        guard let v = self[k] else { return nil }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s.trimmingCharacters(in: .whitespaces)) ?? Double(s).map { Int($0) } }
        return nil
    }
    func int64(_ k: String) -> Int64? {
        if let n = self[k] as? Int64 { return n }
        if let n = self[k] as? NSNumber { return n.int64Value }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    func bool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.boolValue }
        if let s = self[k] as? String { return ["true", "yes", "1", "on"].contains(s.lowercased()) }
        return nil
    }
    func strings(_ k: String) -> [String]? {
        if let a = self[k] as? [Any] {
            let out = a.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return out.isEmpty ? nil : out
        }
        if let s = self[k] as? String {
            let out = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return out.isEmpty ? nil : out
        }
        return nil
    }
    func data(_ k: String) -> Data? { self[k] as? Data }
}

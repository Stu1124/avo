import Foundation

/// Pure helpers that turn model-supplied JSON into tables, pretty JSON, and chart series.
/// Kept free of SwiftUI so the unit test can compile it on its own.
enum ArtifactFormat {
    /// Pretty-printed JSON text, or nil when `raw` is not JSON.
    static func prettyJSON(_ raw: Any) -> String? {
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return stringify(obj)
        }
        return stringify(raw)
    }

    static func stringify(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Accepts a JSON object, a JSON array, or a JSON string under `key`.
    static func jsonValue(_ args: [String: Any], key: String) -> Any? {
        guard let raw = args[key] else { return nil }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
            return trimmed
        }
        return raw
    }

    /// Columns plus row cells. Rows may be arrays or objects keyed by column name.
    static func table(from args: [String: Any]) -> (columns: [String], rows: [[String]])? {
        var columns = stringList(args["columns"])
        var rawRows = objectList(args["rows"])
        if rawRows.isEmpty, let s = args["rows"] as? String {
            if let arr = decodeArray(s) { rawRows = arr }
        }
        if columns.isEmpty, let first = rawRows.first {
            if let obj = first as? [String: Any] {
                columns = obj.keys.sorted()
            } else if let arr = first as? [Any] {
                columns = arr.enumerated().map { "Col \($0.offset + 1)" }
            }
        }
        guard !columns.isEmpty, !rawRows.isEmpty else { return nil }
        let rows: [[String]] = rawRows.prefix(24).map { row in
            if let obj = row as? [String: Any] {
                return columns.map { cell(obj[$0]) }
            }
            if let arr = row as? [Any] {
                return columns.indices.map { $0 < arr.count ? cell(arr[$0]) : "" }
            }
            if let arr = row as? [String] {
                return columns.indices.map { $0 < arr.count ? arr[$0] : "" }
            }
            return columns.map { _ in cell(row) }
        }
        guard rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return nil }
        return (columns, rows)
    }

    static func chartItems(_ raw: Any?) -> [(label: String, value: Double)] {
        var items: [[String: Any]] = []
        if let arr = raw as? [[String: Any]] { items = arr }
        else if let arr = raw as? [Any] { items = arr.compactMap { $0 as? [String: Any] } }
        else if let s = raw as? String, let arr = decodeArray(s) {
            items = arr.compactMap { $0 as? [String: Any] }
        }
        return items.prefix(12).compactMap { it in
            let label = (it["label"] as? String) ?? (it["title"] as? String) ?? (it["name"] as? String)
            guard let label, !label.isEmpty else { return nil }
            let value: Double
            if let n = it["value"] as? Double { value = n }
            else if let n = it["value"] as? Int { value = Double(n) }
            else if let n = it["value"] as? NSNumber { value = n.doubleValue }
            else if let s = it["value"] as? String, let n = Double(s) { value = n }
            else { return nil }
            return (label, value)
        }
    }

    static func stringList(_ raw: Any?) -> [String] {
        if let arr = raw as? [String] { return arr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let arr = raw as? [Any] { return arr.compactMap { cell($0) }.filter { !$0.isEmpty } }
        if let s = raw as? String {
            if let arr = decodeArray(s) { return arr.compactMap { cell($0) }.filter { !$0.isEmpty } }
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    static func cell(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let b = v as? Bool { return b ? "true" : "false" }
        if JSONSerialization.isValidJSONObject(v),
           let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) { return s }
        return "\(v)"
    }

    private static func objectList(_ raw: Any?) -> [Any] {
        if let arr = raw as? [Any] { return arr }
        return []
    }

    private static func decodeArray(_ s: String) -> [Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }
}

/// A JSON value the tree viewer can walk without Foundation's untyped Any.
enum JSONNode {
    case object([(String, JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func parse(_ raw: Any) -> JSONNode {
        if raw is NSNull { return .null }
        if let b = raw as? Bool { return .bool(b) }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.stringValue)
        }
        if let s = raw as? String { return .string(s) }
        if let arr = raw as? [Any] { return .array(arr.map { parse($0) }) }
        if let obj = raw as? [String: Any] {
            return .object(obj.keys.sorted().map { ($0, parse(obj[$0] as Any)) })
        }
        return .string("\(raw)")
    }

    static func parse(text: String) -> JSONNode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(obj)
    }

    var preview: String {
        switch self {
        case .object(let pairs): return "{\(pairs.count)}"
        case .array(let items): return "[\(items.count)]"
        case .string(let s): return s.count > 40 ? String(s.prefix(37)) + "…" : s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }
}

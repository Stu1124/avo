import Foundation

/// JSON value helper for tool arguments.
enum JSON {
    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func stringify(_ obj: Any, pretty: Bool = false) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
    static func parse(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }
}

struct ToolParam {
    var name: String
    var type: String            // string, number, integer, boolean, array, object
    var description: String
    var required = false
    var enumValues: [String]? = nil
    var items: String? = nil    // item type for arrays
    init(_ name: String, _ type: String = "string", _ description: String, required: Bool = false, enumValues: [String]? = nil, items: String? = nil) {
        self.name = name; self.type = type; self.description = description; self.required = required; self.enumValues = enumValues; self.items = items
    }
}

/// What a tool hands back: JSON for the model, optional cards for the user, optional spoken line override.
struct ToolResult {
    var json: [String: Any]
    var cards: [CardKind] = []
    var ok: Bool = true
    /// If set on a confirmed acting tool, Avo says this directly and skips the final model round trip.
    var narration: String? = nil
    /// Images the model should see next (function outputs are text-only, so the runtime attaches these
    /// as a follow-up user message).
    var imagePaths: [String] = []
    static func ok(_ json: [String: Any], cards: [CardKind] = [], narration: String? = nil) -> ToolResult { .init(json: json, cards: cards, ok: true, narration: narration) }
    static func fail(_ message: String, guidance: String? = nil) -> ToolResult {
        var j: [String: Any] = ["ok": false, "error": message]
        if let g = guidance { j["guidance"] = g }
        return .init(json: j, cards: [], ok: false)
    }
}

/// Confirmation spec: how to show the card before running. `nil` = read-only tool, runs immediately.
struct ConfirmationSpec {
    var icon: String
    var title: String
    var subtitle: ((_ args: [String: Any]) -> String?)?
    var fields: [(key: String, label: String, kind: ConfirmationCard.FieldKind, required: Bool)]
    var confirmLabel: String = "Confirm"
    var destructive = false
    var layout: ConfirmationCard.Layout = .generic
}

protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var params: [ToolParam] { get }
    var confirmation: ConfirmationSpec? { get }
    /// Short status chip label while running, e.g. "Fetching".
    var statusLabel: String { get }
    var statusIcon: String { get }
    /// Integration group for settings toggles.
    var group: String { get }
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult
}

extension Tool {
    var confirmation: ConfirmationSpec? { nil }
    var statusIcon: String { "circle.dotted" }
    var schema: [String: Any] {
        var props: [String: Any] = [:]
        for p in params {
            var d: [String: Any] = ["type": p.type, "description": p.description]
            if let e = p.enumValues { d["enum"] = e }
            if p.type == "array" { d["items"] = ["type": p.items ?? "string"] }
            props[p.name] = d
        }
        return ["type": "object", "properties": props, "required": params.filter { $0.required }.map { $0.name }, "additionalProperties": false]
    }
    /// Read tools get a `show` flag: results become a card only when the model asks for it.
    var openAIDefinition: [String: Any] {
        var params = (self as? MCPTool)?.rawSchema ?? schema
        if confirmation == nil, var props = params["properties"] as? [String: Any], props["show"] == nil {
            props["show"] = ["type": "boolean", "description": "Set true to display these results to the user as a card. Only when the user asked to see them (show/list/what are my…) or the list itself is the answer. Leave false when you are just reading data to answer a question; use present_list to show a hand-picked subset instead."]
            params["properties"] = props
        }
        return ["type": "function", "name": name, "description": description, "parameters": params]
    }
}

/// Per-turn context handed to tools.
struct ToolContext {
    var turnId: UUID
    var screenshotPath: String?
    var selectedText: String?
    var frontmostApp: String?
    var frontmostBundleId: String?
    var clipboard: String?
    var openCardTaskId: String?
    var attachments: [String]
    var transcript: String
}

@MainActor
final class ToolRegistry {
    static let shared = ToolRegistry()
    private(set) var tools: [String: Tool] = [:]
    private(set) var order: [String] = []
    /// Re-registering a name replaces the tool and keeps its place. Appending unconditionally left
    /// the name in `order` twice, and `all` then handed the model the same tool twice — which is what
    /// happens the moment anything re-registers a source, as "Restart servers" does for MCP.
    func register(_ t: Tool) {
        if tools[t.name] == nil { order.append(t.name) }
        tools[t.name] = t
    }
    func register(_ ts: [Tool]) { ts.forEach(register) }
    /// Drops every tool whose group starts with `prefix`, so that source can be registered afresh.
    func unregister(groupPrefix prefix: String) { drop { $0.group.hasPrefix(prefix) } }
    /// Drops one group exactly. `groupPrefix` would take "MCP: linear-cloud" along with "MCP: linear".
    func unregister(group: String) { drop { $0.group == group } }
    private func drop(_ matches: (Tool) -> Bool) {
        let names = Set(tools.filter { matches($0.value) }.keys)
        guard !names.isEmpty else { return }
        for n in names { tools.removeValue(forKey: n) }
        order.removeAll { names.contains($0) }
    }
    var all: [Tool] { order.compactMap { tools[$0] } }
    func enabled() -> [Tool] {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledToolGroups") ?? [])
        return all.filter { !disabled.contains($0.group) }
    }
    func tool(_ name: String) -> Tool? { tools[name] }
}

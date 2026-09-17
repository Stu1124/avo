// deps: Avo/Cards/ArtifactFormat.swift Avo/Notch/CodeHighlight.swift
import Foundation

@main
struct ArtifactFormatTests {
    static func main() {
        // Table from columns + array rows.
        let t1 = ArtifactFormat.table(from: [
            "columns": ["Name", "Role"],
            "rows": [["Ada", "Engineer"], ["Grace", "Admiral"]],
        ])
        precondition(t1?.columns == ["Name", "Role"], "Got \(String(describing: t1?.columns))")
        precondition(t1?.rows == [["Ada", "Engineer"], ["Grace", "Admiral"]], "Got \(String(describing: t1?.rows))")

        // Table from object rows; columns inferred and sorted when omitted.
        let t2 = ArtifactFormat.table(from: [
            "rows": [["city": "Paris", "temp": 18], ["city": "Oslo", "temp": 4]],
        ])
        precondition(t2?.columns == ["city", "temp"], "Got \(String(describing: t2?.columns))")
        precondition(t2?.rows.first == ["Paris", "18"], "Got \(String(describing: t2?.rows))")

        // JSON string or object both pretty-print.
        let pretty = ArtifactFormat.prettyJSON("{\"b\":2,\"a\":1}")
        precondition(pretty?.contains("\"a\"") == true && pretty?.contains("\n") == true, "Got \(String(describing: pretty))")
        let fromObj = ArtifactFormat.prettyJSON(["ok": true, "n": 3])
        precondition(fromObj?.contains("\"ok\"") == true, "Got \(String(describing: fromObj))")
        precondition(ArtifactFormat.jsonValue(["json": "{\"x\":1}"], key: "json") is [String: Any])
        precondition(ArtifactFormat.jsonValue(["json": ["x": 1] as [String: Any]], key: "json") is [String: Any])

        let node = JSONNode.parse(text: "{\"user\":\"ada\",\"tags\":[\"a\",1,true,null]}")
        guard case .object(let pairs) = node else { preconditionFailure("expected object") }
        precondition(pairs.contains(where: { $0.0 == "user" }), "missing user")
        guard let tags = pairs.first(where: { $0.0 == "tags" })?.1, case .array(let items) = tags else {
            preconditionFailure("expected tags array")
        }
        precondition(items.count == 4, "Got \(items.count)")
        guard case .bool(true) = items[2], case .null = items[3] else { preconditionFailure("bool/null") }
        precondition(JSONNode.parse(text: "not json") == nil)

        let items: [[String: Any]] = [["label": "Mon", "value": 3], ["title": "Tue", "value": "4.5"]]
        let chart = ArtifactFormat.chartItems(items)
        precondition(chart.map(\.label) == ["Mon", "Tue"], "Got \(chart.map(\.label))")
        precondition(chart.map(\.value) == [3, 4.5], "Got \(chart.map(\.value))")

        // Highlighter: JSON keywords, strings, numbers; Swift keywords; comments.
        let jsonTok = CodeHighlight.tokens("{\"ok\": true, \"n\": 2}", language: "json")
        precondition(jsonTok.contains(where: { $0.text == "true" && $0.kind == .keyword }), "true should be a keyword")
        precondition(jsonTok.contains(where: { $0.text.hasPrefix("\"ok\"") && $0.kind == .string }), "keys are strings")
        precondition(jsonTok.contains(where: { $0.text == "2" && $0.kind == .number }), "2 should be a number")

        let swiftTok = CodeHighlight.tokens("let x = \"hi\" // c", language: "swift")
        precondition(swiftTok.contains(where: { $0.text == "let" && $0.kind == .keyword }))
        precondition(swiftTok.contains(where: { $0.text.hasPrefix("\"hi\"") && $0.kind == .string }))
        precondition(swiftTok.contains(where: { $0.text.contains("c") && $0.kind == .comment }))

        let pyTok = CodeHighlight.tokens("def f():\n    return 1  # n", language: "python")
        precondition(pyTok.contains(where: { $0.text == "def" && $0.kind == .keyword }))
        precondition(pyTok.contains(where: { $0.kind == .comment && $0.text.contains("#") }))

        print("PASS: tables, JSON pretty/tree, charts, code tokens")
    }
}

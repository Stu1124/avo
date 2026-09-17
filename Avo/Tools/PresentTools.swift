import Foundation

/// Lets the model decide exactly what the user sees: lists, tables, JSON, code, markdown, and charts.
enum PresentTools {
    static func all() -> [Tool] {
        [PresentList(), PresentTable(), PresentJSON(), PresentCode(), PresentMarkdown(), PresentChart()]
    }

    struct PresentList: Tool {
        let name = "present_list"
        let description = "Show the user a card with a hand-picked list of items you selected from earlier results — e.g. the 3 emails that need a reply, the 2 files that match, tomorrow's 4 events. Use this instead of showing raw tool results. Keep it to what matters (max 8 rows). Each row can carry a url or file path so clicking opens it. The card always appears; do not also dump the same list as spoken bullets."
        let params = [
            ToolParam("title", "string", "Short card title, e.g. 'Needs a reply' or 'Tomorrow'.", required: true),
            ToolParam("items", "array", "Rows: JSON objects with title (required), subtitle, trailing (short right-side text like a time), url, path.", required: true, items: "object"),
            ToolParam("source", "string", "Where these came from, shown as a footer chip: Gmail, Google Calendar, Messages, Finder, Drive, Notes…"),
        ]
        let statusLabel = "Preparing"
        let statusIcon = "list.bullet"
        let group = "Avo"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let title = (args["title"] as? String) ?? "Results"
            var raw = args["items"] as? [[String: Any]] ?? []
            if raw.isEmpty, let s = args["items"] as? String, let arr = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [[String: Any]] { raw = arr }
            let rows = raw.prefix(8).compactMap { r -> GlanceCard.Row? in
                guard let t = r["title"] as? String, !t.isEmpty else { return nil }
                return GlanceCard.Row(title: t, subtitle: r["subtitle"] as? String, icon: nil, trailing: r["trailing"] as? String, url: r["url"] as? String, path: r["path"] as? String)
            }
            guard !rows.isEmpty else { return .fail("No items to show.") }
            let src = args["source"] as? String
            let icon: String? = switch (src ?? "").lowercased() {
                case "gmail": "envelope.fill"; case "google calendar", "calendar": "calendar"; case "messages", "imessage": "app:com.apple.MobileSMS"
                case "finder", "files": "app:com.apple.finder"; case "drive", "google drive": "externaldrive.fill"; case "notes": "app:com.apple.Notes"
                default: nil }
            let card = GlanceCard(id: UUID(), blocks: [.header(title: title, subtitle: nil, icon: icon ?? "list.bullet"), .list(rows: rows)], source: src, sourceIcon: icon)
            return .ok(["ok": true, "shown": rows.count, "kind": "list"], cards: [.glance(card)])
        }
    }

    struct PresentTable: Tool {
        let name = "present_table"
        let description = "Show a comparison table card. Use for side-by-side options, schedules, rankings, specs, or any grid the user should scan. Prefer this over markdown tables in the spoken reply. Max 24 rows."
        let params = [
            ToolParam("title", "string", "Short card title.", required: true),
            ToolParam("columns", "array", "Column headers, left to right.", required: true, items: "string"),
            ToolParam("rows", "array", "Each row is an array of cell strings in column order, or an object keyed by column name.", required: true, items: "object"),
            ToolParam("subtitle", "string", "Optional one-line caption under the title."),
        ]
        let statusLabel = "Table"
        let statusIcon = "tablecells"
        let group = "Avo"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let parsed = ArtifactFormat.table(from: args) else {
                return .fail("Need columns and at least one row.", guidance: "Pass columns as an array of strings and rows as arrays or objects.")
            }
            let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Table"
            let card = ArtifactCard(id: UUID(), kind: .table, title: title, subtitle: args["subtitle"] as? String,
                                    table: .init(columns: parsed.columns, rows: parsed.rows))
            return .ok(["ok": true, "shown": parsed.rows.count, "columns": parsed.columns.count, "kind": "table"],
                       cards: [.artifact(card)])
        }
    }

    struct PresentJSON: Tool {
        let name = "present_json"
        let description = "Show a JSON artifact card with a collapsible tree the user can inspect and copy. Use when the answer is structured data: an API payload, a config, a parsed object, or anything the user asked to see as JSON."
        let params = [
            ToolParam("title", "string", "Short card title.", required: true),
            ToolParam("json", "string", "The JSON value. Pass a JSON object, array, or a JSON string.", required: true),
            ToolParam("subtitle", "string", "Optional one-line caption."),
        ]
        let statusLabel = "JSON"
        let statusIcon = "curlybraces"
        let group = "Avo"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "JSON"
            guard let value = ArtifactFormat.jsonValue(args, key: "json") else {
                return .fail("Need a json object, array, or string.")
            }
            let pretty: String
            if let s = ArtifactFormat.prettyJSON(value) {
                pretty = s
            } else if let s = value as? String {
                pretty = s
            } else {
                return .fail("Could not serialise that JSON.")
            }
            let card = ArtifactCard(id: UUID(), kind: .json, title: title, subtitle: args["subtitle"] as? String, language: "json", body: pretty)
            return .ok(["ok": true, "kind": "json", "bytes": pretty.utf8.count], cards: [.artifact(card)])
        }
    }

    struct PresentCode: Tool {
        let name = "present_code"
        let description = "Show a syntax-highlighted code card the user can copy. Use for snippets, commands, configs, patches, or any code they asked to see. Do not paste large code into the spoken reply."
        let params = [
            ToolParam("title", "string", "Short card title.", required: true),
            ToolParam("code", "string", "The source to show.", required: true),
            ToolParam("language", "string", "Language id for highlighting: swift, python, javascript, json, bash, yaml, cpp…"),
            ToolParam("subtitle", "string", "Optional one-line caption, e.g. a file path."),
        ]
        let statusLabel = "Code"
        let statusIcon = "chevron.left.forwardslash.chevron.right"
        let group = "Avo"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let code = (args["code"] as? String) ?? ""
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .fail("Need code to show.") }
            let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Code"
            let lang = args["language"] as? String
            let card = ArtifactCard(id: UUID(), kind: .code, title: title, subtitle: args["subtitle"] as? String, language: lang, body: code)
            return .ok(["ok": true, "kind": "code", "language": lang ?? "", "lines": code.components(separatedBy: "\n").count],
                       cards: [.artifact(card)])
        }
    }

    struct PresentMarkdown: Tool {
        let name = "present_markdown"
        let description = "Show a formatted document card (headings, lists, tables, code, math). Use for plans, summaries, write-ups, or anything longer than a spoken line that the user should read. Keep the spoken reply to one line pointing at the card."
        let params = [
            ToolParam("title", "string", "Short card title.", required: true),
            ToolParam("markdown", "string", "GitHub-flavoured markdown. Tables, fenced code, lists and math are rendered.", required: true),
            ToolParam("subtitle", "string", "Optional one-line caption."),
        ]
        let statusLabel = "Document"
        let statusIcon = "doc.richtext"
        let group = "Avo"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let md = (args["markdown"] as? String) ?? ""
            guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .fail("Need markdown to show.") }
            let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Document"
            let card = ArtifactCard(id: UUID(), kind: .markdown, title: title, subtitle: args["subtitle"] as? String, body: md)
            return .ok(["ok": true, "kind": "markdown", "chars": md.count], cards: [.artifact(card)])
        }
    }

    struct PresentChart: Tool {
        let name = "present_chart"
        let description = "Show a small chart card. Use for numeric comparisons: bars, a line over a short series, or a handful of stats. Pass up to 12 items with label and value."
        let params = [
            ToolParam("title", "string", "Short card title.", required: true),
            ToolParam("kind", "string", "bars, line, or stats.", required: true, enumValues: ["bars", "line", "stats"]),
            ToolParam("items", "array", "Objects with label (or title/name) and numeric value.", required: true, items: "object"),
            ToolParam("subtitle", "string", "Optional one-line caption."),
        ]
        let statusLabel = "Chart"
        let statusIcon = "chart.bar.fill"
        let group = "Avo"
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let series = ArtifactFormat.chartItems(args["items"])
            guard !series.isEmpty else { return .fail("Need items with label and value.") }
            let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Chart"
            let kindRaw = (args["kind"] as? String)?.lowercased() ?? "bars"
            let kind: ArtifactCard.ChartKind = kindRaw == "line" ? .line : kindRaw == "stats" ? .stats : .bars
            let card = ArtifactCard(id: UUID(), kind: .chart, title: title, subtitle: args["subtitle"] as? String,
                                    chartKind: kind, chartItems: series.map { .init(label: $0.label, value: $0.value) })
            return .ok(["ok": true, "kind": "chart", "shown": series.count], cards: [.artifact(card)])
        }
    }
}

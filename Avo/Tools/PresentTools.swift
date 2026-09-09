import Foundation

/// Lets the model decide exactly what the user sees: a hand-picked list card.
enum PresentTools {
    static func all() -> [Tool] { [PresentList()] }

    struct PresentList: Tool {
        let name = "present_list"
        let description = "Show the user a card with a hand-picked list of items you selected from earlier results — e.g. the 3 emails that need a reply, the 2 files that match, tomorrow's 4 events. Use this instead of showing raw tool results. Keep it to what matters (max 8 rows). Each row can carry a url or file path so clicking opens it."
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
            return .ok(["ok": true, "shown": rows.count], cards: [.glance(card)])
        }
    }
}

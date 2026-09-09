import Foundation

/// The web, for every provider. OpenAI's Responses API carries its own hosted search; nothing else
/// Avo can be pointed at does, so these two tools give Ollama, LM Studio, OpenRouter, Groq and xAI
/// the same reach. No API key and no account: `web_search` reads DuckDuckGo's HTML results page and
/// `read_page` fetches one page and hands back its text.
enum WebTools {
    static let group = "Web"
    static let icon = "globe"

    /// A desktop browser string. DuckDuckGo's HTML endpoint serves an empty page to clients that
    /// look automated, and the parse then finds nothing.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// The set this provider wants. On OpenAI's Responses style the model already gets the hosted
    /// `web_search` tool on every request — that one runs on OpenAI's side, reads the pages itself
    /// and returns citations, so it beats scraping a results page. Registering ours alongside it
    /// would only give the model two ways to do one thing. `read_page` is useful either way.
    @MainActor
    static func all() -> [Tool] {
        let hostedSearch = Brain.style == .responses && Settings.shared.isOpenAIHost
        return hostedSearch ? [ReadPageTool()] : [WebSearchTool(), ReadPageTool()]
    }

    /// Swaps the Web group for the set the current provider wants. Called once at launch and again
    /// whenever the provider style or base URL changes, because that is what decides the set.
    @MainActor
    static func reregister() {
        let registry = ToolRegistry.shared
        registry.unregister(group: group)
        registry.register(all())
    }

    static let unavailable = ToolResult.fail(
        "Search is unavailable right now.",
        guidance: "Tell the user web search did not respond and answer from what you know.")
}

// MARK: - web_search

private struct WebSearchTool: Tool {
    let name = "web_search"
    let description = """
    Searches the web and hands back a handful of results, each with a title, a url and a short snippet. \
    Reach for it whenever the answer turns on something you cannot know from training: news and current \
    events, anything the user calls latest or newest or asks about today, prices, scores, weather, \
    release versions, opening hours, who holds an office now — and any fact you are not sure enough of to \
    state plainly. Search FIRST and answer from what comes back, rather than guessing or offering to \
    check later. It is the wrong tool for anything living on this Mac or in the user's own accounts: \
    files, mail, calendar, messages, reminders and notes each have their own tool. NEVER invent a result, \
    a headline, a number or a url — the snippets are all you have, and where they are too thin, open one \
    with read_page. Say where the answer came from and give the source urls in your reply.
    """
    let params = [
        ToolParam("query", "string", "What to look for, worded the way it would be typed into a search box — the words that matter, not a full sentence.", required: true),
        ToolParam("max_results", "integer", "How many results to bring back. Defaults to 5, and 8 is the most that will be returned."),
    ]
    let statusLabel = "Searching the web"
    let statusIcon = WebTools.icon
    let group = WebTools.group

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        let query = (JSON.string(args["query"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .fail("query is required", guidance: "Call web_search again with the words to search for.")
        }
        let asked = (args["max_results"] as? NSNumber)?.intValue ?? Int(JSON.string(args["max_results"]) ?? "") ?? 5
        let limit = min(max(asked, 1), 8)

        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else { return WebTools.unavailable }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(WebTools.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                Log.info("web_search: HTTP \(code)")
                return WebTools.unavailable
            }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let results = DDGParser.results(from: html, limit: limit)
            guard !results.isEmpty else {
                Log.info("web_search: no results parsed from \(data.count) bytes")
                return WebTools.unavailable
            }
            let rows = results.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] }
            return .ok([
                "ok": true, "query": query, "count": rows.count, "results": rows,
                "guidance": "Answer from these snippets and name the sources with their urls. Where a snippet is too thin, call read_page on the most promising url. Do not state anything the results do not support.",
            ])
        } catch {
            Log.info("web_search: \(error.localizedDescription)")
            return WebTools.unavailable
        }
    }
}

// MARK: - read_page

private struct ReadPageTool: Tool {
    let name = "read_page"
    let description = """
    Fetches one web page and hands back its readable text — roughly the first 6,000 characters — along with \
    the page title. Two things call for it. After web_search, where a snippet is too thin to answer from \
    and the real answer is on the page. And where the user hands you a url and wants what is on it read, \
    summarised, quoted or checked. One address per call, http or https, written out in full. It cannot \
    sign in, fill a form, or reach anything behind a paywall or a login, and it is not how you open a file \
    on this Mac. Answer from the text that comes back, never from what you assume the page says, and cite \
    the url in your reply.
    """
    let params = [ToolParam("url", "string", "The full address of the page, including https://.", required: true)]
    let statusLabel = "Reading page"
    let statusIcon = "doc.text"
    let group = WebTools.group

    /// Enough of a page to answer from, and a hard ceiling on what is pulled over the wire so a
    /// video or an image served at an https url cannot swallow the turn.
    private static let textLimit = 6000
    private static let byteLimit = 1_500_000

    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        var raw = (JSON.string(args["url"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return .fail("A full http or https url is required.",
                         guidance: "Call read_page again with the complete address, or search for the page first with web_search.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(WebTools.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            guard code == 200 else {
                return .fail("The page returned HTTP \(code).",
                             guidance: "Tell the user that page did not load, and answer from the search snippets or from what you know.")
            }
            let capped = data.count > Self.byteLimit ? data.prefix(Self.byteLimit) : data[...]
            let html = String(decoding: capped, as: UTF8.self)
            let text = DDGParser.readableText(fromHTML: html, limit: Self.textLimit)
            guard !text.isEmpty else {
                return .fail("That page has no readable text.",
                             guidance: "Tell the user the page could not be read as text — it may be a PDF, a video or an app — and offer to search instead.")
            }
            var json: [String: Any] = [
                "ok": true,
                "url": (http?.url ?? url).absoluteString,
                "text": text,
                "chars": text.count,
                "truncated": text.count >= Self.textLimit,
            ]
            let title = DDGParser.title(fromHTML: html)
            if !title.isEmpty { json["title"] = title }
            json["guidance"] = "Answer from this text only, and cite the url. Where it was truncated and the answer is not in it, say so rather than filling the gap."
            return .ok(json)
        } catch {
            Log.info("read_page: \(error.localizedDescription)")
            return .fail("That page did not load.",
                         guidance: "Tell the user the page did not respond, and answer from what you already have.")
        }
    }
}

import Foundation

/// OpenAI Responses API streaming client with function tools, reasoning effort, and built-in web search.
final class ResponsesClient: BrainClient {
    private let sse = SSESession()

    struct Parser: SSEEventParser {
        var partialTools: [String: (callId: String, name: String, args: String)] = [:]
        mutating func feed(_ chunk: Data) -> [BrainEvent] { ResponsesClient.parse(chunk, partialTools: &partialTools) }
        mutating func finish() -> [BrainEvent] { [] }
    }

    /// Streams a Responses API call. `input` is a prebuilt Responses `input` array (messages + function outputs).
    @MainActor
    func stream(model: String, effort: String?, instructions: String, input: [[String: Any]], tools: [[String: Any]]) -> AsyncStream<BrainEvent> {
        let s = Settings.shared
        guard let key = s.apiKey, !key.isEmpty else {
            return AsyncStream { c in c.yield(.error("API key missing. Add it in Settings → General → Model.")); c.finish() }
        }
        let allTools = s.isOpenAIHost ? tools + [["type": "web_search"]] : tools
        let body = RequestPolicy.body(model: model, effort: effort, instructions: instructions, input: input,
                                      tools: allTools, stream: true, maxTokens: effort == "none" ? 4096 : 16384)
        var req = URLRequest(url: ProviderURL.endpoint("responses", base: s.apiBaseURL))
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return sse.stream(req, parser: Parser(), providerLabel: "Provider")
    }

    static func parse(_ chunk: Data, partialTools: inout [String: (callId: String, name: String, args: String)]) -> [BrainEvent] {
        guard let text = String(data: chunk, encoding: .utf8) else { return [] }
        var dataLine = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("data:") { dataLine += line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        }
        guard !dataLine.isEmpty, dataLine != "[DONE]",
              let obj = try? JSONSerialization.jsonObject(with: Data(dataLine.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        switch type {
        case "response.output_text.delta":
            if let d = obj["delta"] as? String { return [.textDelta(d)] }
        case "response.reasoning_summary_text.delta":
            if let d = obj["delta"] as? String { return [.reasoningSummary(d)] }
        case "response.output_item.added":
            if let item = obj["item"] as? [String: Any], item["type"] as? String == "function_call",
               let id = item["id"] as? String {
                partialTools[id] = (item["call_id"] as? String ?? id, item["name"] as? String ?? "", item["arguments"] as? String ?? "")
            } else if let item = obj["item"] as? [String: Any], item["type"] as? String == "web_search_call" {
                return [.webSearchStarted]
            }
        case "response.output_text.annotation.added":
            if let a = obj["annotation"] as? [String: Any], a["type"] as? String == "url_citation",
               let url = a["url"] as? String {
                return [.citation(title: a["title"] as? String ?? url, url: url)]
            }
        case "response.function_call_arguments.delta":
            if let id = obj["item_id"] as? String, let d = obj["delta"] as? String, var t = partialTools[id] {
                t.args += d; partialTools[id] = t
            }
        case "response.output_item.done":
            if let item = obj["item"] as? [String: Any], item["type"] as? String == "function_call",
               let id = item["id"] as? String {
                let callId = item["call_id"] as? String ?? partialTools[id]?.callId ?? id
                let name = item["name"] as? String ?? partialTools[id]?.name ?? ""
                let args = item["arguments"] as? String ?? partialTools[id]?.args ?? "{}"
                partialTools[id] = nil
                return [.toolCall(id: id, callId: callId, name: name, arguments: args)]
            }
        case "response.completed":
            let r = obj["response"] as? [String: Any]
            return [.completed(responseId: r?["id"] as? String ?? "", usage: r?["usage"] as? [String: Any])]
        case "response.incomplete":
            let response = obj["response"] as? [String: Any]
            let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "unknown"
            return [.completed(responseId: response?["id"] as? String ?? "", usage: response?["usage"] as? [String: Any]),
                    .error("Response stopped before completion (\(reason)). Try a narrower request or Deep mode.")]
        case "response.failed", "error":
            let msg = ((obj["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                ?? (obj["error"] as? [String: Any])?["message"] as? String ?? obj["message"] as? String ?? "Model error"
            return [.error(msg)]
        default: break
        }
        return []
    }

    /// Non-streaming helper for small side calls (summaries, classification).
    @MainActor
    func complete(model: String, instructions: String, prompt: String, maxTokens: Int) async -> String? {
        guard let key = Settings.shared.apiKey else { return nil }
        let body = RequestPolicy.body(model: model, effort: "low", instructions: instructions,
                                      input: [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
                                      tools: [], stream: false, maxTokens: maxTokens, cachePrefix: false)
        var req = URLRequest(url: ProviderURL.endpoint("responses", base: Settings.shared.apiBaseURL))
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = obj["output"] as? [[String: Any]] else { return nil }
        for item in output where item["type"] as? String == "message" {
            for c in item["content"] as? [[String: Any]] ?? [] where c["type"] as? String == "output_text" {
                return c["text"] as? String
            }
        }
        return nil
    }
}

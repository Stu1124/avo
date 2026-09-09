import Foundation

/// Parses chat-completions SSE blocks into BrainEvents. Tool-call argument deltas arrive split across
/// chunks keyed by `index`; they are assembled and emitted when the choice finishes.
struct ChatSSEParser: SSEEventParser {
    private var partial: [Int: (id: String, name: String, args: String)] = [:]
    private var order: [Int] = []
    private var responseId = ""
    private var usage: [String: Any]?
    private var toolsFlushed = false
    private var completed = false

    mutating func feed(_ block: Data) -> [BrainEvent] {
        guard let text = String(data: block, encoding: .utf8) else { return [] }
        var payload = ""
        for line in text.split(separator: "\n") where line.hasPrefix("data:") {
            payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        }
        if payload.isEmpty { return [] }
        if payload == "[DONE]" { return finish() }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return [] }
        if let err = obj["error"] as? [String: Any] {
            return [.error(err["message"] as? String ?? "Model error")]
        }
        var events: [BrainEvent] = []
        if let id = obj["id"] as? String, !id.isEmpty { responseId = id }
        if let u = obj["usage"] as? [String: Any] { usage = normalize(u) }
        if let choice = (obj["choices"] as? [[String: Any]])?.first {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let c = delta["content"] as? String, !c.isEmpty { events.append(.textDelta(c)) }
            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let idx = (tc["index"] as? NSNumber)?.intValue ?? 0
                var cur = partial[idx] ?? (id: "", name: "", args: "")
                if partial[idx] == nil { order.append(idx) }
                if let id = tc["id"] as? String, !id.isEmpty { cur.id = id }
                if let f = tc["function"] as? [String: Any] {
                    if let n = f["name"] as? String, !n.isEmpty { cur.name = n }
                    if let a = f["arguments"] as? String { cur.args += a }
                }
                partial[idx] = cur
            }
            if choice["finish_reason"] != nil, !(choice["finish_reason"] is NSNull) { events += flushTools() }
        }
        return events
    }

    mutating func finish() -> [BrainEvent] {
        var events = flushTools()
        if !completed { completed = true; events.append(.completed(responseId: responseId, usage: usage)) }
        return events
    }

    private mutating func flushTools() -> [BrainEvent] {
        guard !toolsFlushed, !partial.isEmpty else { return [] }
        toolsFlushed = true
        return order.compactMap { idx in
            guard let t = partial[idx] else { return nil }
            let id = t.id.isEmpty ? "call_\(idx)" : t.id
            return .toolCall(id: id, callId: id, name: t.name, arguments: t.args.isEmpty ? "{}" : t.args)
        }
    }

    /// Chat usage keys → the Responses keys the runtime already logs.
    private func normalize(_ u: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out["input_tokens"] = (u["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        out["output_tokens"] = (u["completion_tokens"] as? NSNumber)?.intValue ?? 0
        if let d = u["prompt_tokens_details"] as? [String: Any], let c = d["cached_tokens"] { out["input_tokens_details"] = ["cached_tokens": c] }
        return out
    }
}

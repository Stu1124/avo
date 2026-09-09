// deps: Avo/Agent/ChatSSEParser.swift Avo/Agent/BrainClient.swift
import Foundation

@main
struct ChatSSEParserTests {
    static func block(_ json: String) -> Data { Data(("data: " + json).utf8) }
    static func main() {
        var p = ChatSSEParser()
        var events: [BrainEvent] = []
        events += p.feed(block(#"{"id":"r1","choices":[{"delta":{"role":"assistant","content":"Hel"}}]}"#))
        events += p.feed(block(#"{"id":"r1","choices":[{"delta":{"content":"lo"}}]}"#))
        events += p.feed(block(#"{"id":"r1","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"now","arguments":""}}]}}]}"#))
        events += p.feed(block(#"{"id":"r1","choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"list","arguments":"{\"n\""}}]}}]}"#))
        events += p.feed(block(#"{"id":"r1","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}"#))
        events += p.feed(block(#"{"id":"r1","choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":":3}"}}]}}]}"#))
        events += p.feed(Data("data: not json".utf8))
        events += p.feed(block(#"{"id":"r1","choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
        events += p.feed(block(#"{"id":"r1","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":5}}"#))
        events += p.feed(Data("data: [DONE]".utf8))
        events += p.finish()

        var text = ""; var calls: [(String, String, String)] = []; var completed = 0; var usage: [String: Any]?
        for e in events {
            switch e {
            case .textDelta(let d): text += d
            case .toolCall(_, let id, let name, let args): calls.append((id, name, args))
            case .completed(let rid, let u): completed += 1; usage = u; precondition(rid == "r1")
            case .error(let m): preconditionFailure("unexpected error \(m)")
            default: break
            }
        }
        precondition(text == "Hello")
        precondition(calls.count == 2 && calls[0] == ("call_a", "now", "{}") && calls[1] == ("call_b", "list", "{\"n\":3}"), "\(calls)")
        precondition(completed == 1, "exactly one completed event, got \(completed)")
        precondition((usage?["input_tokens"] as? Int) == 12 && (usage?["output_tokens"] as? Int) == 5, "usage normalized to Responses keys")

        var q = ChatSSEParser()
        let errs = q.feed(block(#"{"error":{"message":"model not found"}}"#))
        if case .error(let m) = errs.first! { precondition(m == "model not found") } else { preconditionFailure() }

        var r = ChatSSEParser()
        var ev = r.feed(block(#"{"id":"x","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#))
        ev += r.finish()
        precondition(ev.contains { if case .completed = $0 { return true } else { return false } }, "finish() completes a stream that never sent [DONE]")
        // ProviderURL: a bare host gains /v1, an explicit path is left alone, slashes are tolerated.
        precondition(ProviderURL.endpoint("chat/completions", base: "https://api.openai.com").absoluteString == "https://api.openai.com/v1/chat/completions")
        precondition(ProviderURL.endpoint("chat/completions", base: "http://localhost:11434/").absoluteString == "http://localhost:11434/v1/chat/completions")
        precondition(ProviderURL.endpoint("responses", base: "https://api.openai.com/v1").absoluteString == "https://api.openai.com/v1/responses")
        precondition(ProviderURL.endpoint("responses", base: " https://example.com/openai/v1/ ").absoluteString == "https://example.com/openai/v1/responses")
        precondition(ProviderURL.endpoint("responses", base: "https://host/openai").absoluteString == "https://host/openai/responses")

        print("PASS: chat SSE text, split tool-call deltas, usage normalization, errors, finish without DONE, provider URLs")
    }
}

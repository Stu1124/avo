// deps: Avo/Agent/RequestPolicy.swift Avo/Agent/ChatConversion.swift
import Foundation

@main
struct RequestPolicyTests {
    static func main() {
        let tools: [[String: Any]] = [["type": "function", "name": "z"], ["name": "a", "type": "function"]]
        func request(_ text: String, _ definitions: [[String: Any]] = tools) -> [String: Any] {
            RequestPolicy.body(model: "gpt-5.6-luna", effort: "none", instructions: "Stable instructions", input: [["role": "user", "content": text]], tools: definitions, stream: true, maxTokens: 4096)
        }
        let first = request("First screen"), second = request("Different screen", tools.reversed())
        precondition(first["prompt_cache_key"] as? String == second["prompt_cache_key"] as? String, "Dynamic input/tool arrival order must not split routing")
        let messages = first["input"] as! [[String: Any]]
        precondition(messages.count == 2 && messages[0]["role"] as? String == "developer")
        precondition(first["instructions"] == nil)
        let blocks = messages[0]["content"] as! [[String: Any]]
        precondition(blocks[0]["prompt_cache_breakpoint"] != nil)
        precondition((first["prompt_cache_options"] as? [String: String]) == ["mode": "explicit", "ttl": "30m"])
        precondition((first["reasoning"] as! [String: String])["summary"] == nil)
        let uncached = RequestPolicy.body(model: "gpt-5.6-luna", effort: "none", instructions: "One-off", input: [], tools: [], stream: false, maxTokens: 600, cachePrefix: false)
        let uncachedBlocks = (uncached["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        precondition(uncachedBlocks[0]["prompt_cache_breakpoint"] == nil && uncached["prompt_cache_key"] == nil)
        let legacy = RequestPolicy.body(model: "gpt-5.4-mini", effort: "low", instructions: "Legacy", input: [], tools: [], stream: true, maxTokens: 4096)
        precondition(legacy["prompt_cache_options"] == nil && legacy["instructions"] as? String == "Legacy")
        let usage = RequestPolicy.Usage(["input_tokens": 10000, "input_tokens_details": ["cached_tokens": 6000, "cache_write_tokens": 3000], "output_tokens": 500, "output_tokens_details": ["reasoning_tokens": 200]])
        precondition(usage.ordinary == 1000 && usage.hitPercent == 60 && usage.reasoning == 200)
        precondition(abs(usage.estimatedUSD(model: "gpt-5.6-luna")! - 0.00167) < 0.00000001, "Cache writes replace ordinary input; reasoning is already included in output")
        precondition(usage.estimatedUSD(model: "custom-model") == nil)
        print("PASS: request boundaries, stable routing, legacy compatibility, one-off calls, cache-write billing")
    }
}

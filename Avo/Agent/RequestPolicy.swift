import Foundation
import CryptoKit

/// Pure request construction, shared by the app and the regression harness.
enum RequestPolicy {
    static func supportsExplicitCache(_ model: String) -> Bool {
        ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"].contains { model == $0 || model.hasPrefix($0 + "-") }
    }

    static func body(model: String, effort: String?, instructions: String, input: [[String: Any]], tools: [[String: Any]], stream: Bool, maxTokens: Int, cachePrefix: Bool = true) -> [String: Any] {
        let explicit = supportsExplicitCache(model)
        let sortedTools = tools.sorted { ($0["name"] as? String ?? $0["type"] as? String ?? "") < ($1["name"] as? String ?? $1["type"] as? String ?? "") }
        var body: [String: Any] = ["model": model, "input": input, "store": false, "stream": stream, "max_output_tokens": maxTokens]
        if !sortedTools.isEmpty {
            body["tools"] = sortedTools
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }
        if let effort { body["reasoning"] = ["effort": effort] }
        if model.hasPrefix("gpt-5") { body["text"] = ["verbosity": "low"] }
        if explicit {
            // Only reusable instructions + schemas are written. Screenshots, clipboard, and transient
            // tool results remain after this boundary, avoiding speculative cache-write charges.
            var block: [String: Any] = ["type": "input_text", "text": instructions]
            if cachePrefix { block["prompt_cache_breakpoint"] = ["mode": "explicit"] }
            body["input"] = [["role": "developer", "content": [block]]] + input
            body["prompt_cache_options"] = ["mode": "explicit", "ttl": "30m"]
        } else {
            body["instructions"] = instructions
        }
        if cachePrefix {
            let prefix: [String: Any] = ["model": model, "instructions": instructions, "tools": sortedTools, "effort": effort ?? "default", "version": 2]
            let data = (try? JSONSerialization.data(withJSONObject: prefix, options: [.sortedKeys])) ?? Data()
            let hash = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
            body["prompt_cache_key"] = "avo-v2-" + hash
        }
        return body
    }

    /// Chat-completions payload for OpenAI-compatible servers (Ollama, LM Studio, OpenRouter, Groq, xAI...).
    /// No cache keys, no verbosity, no built-in tools: those are Responses-only.
    /// `openAIHost` adapts the two places where OpenAI's own chat endpoint differs from the servers that
    /// copy it: it rejects `max_tokens` on its newer models in favour of `max_completion_tokens`, and it
    /// rejects function tools on a reasoning model unless the effort is stated, including `"none"`.
    /// Third-party servers generally only implement `max_tokens` and reject an unknown effort, so they
    /// keep the older shape.
    static func chatBody(model: String, effort: String?, instructions: String, input: [[String: Any]], tools: [[String: Any]], stream: Bool, maxTokens: Int, openAIHost: Bool = false) -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": ChatConversion.messages(instructions: instructions, input: input),
                                   "stream": stream]
        body[openAIHost ? "max_completion_tokens" : "max_tokens"] = maxTokens
        if stream { body["stream_options"] = ["include_usage": true] }
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        let isReasoningModel = model.hasPrefix("gpt-5") || (model.hasPrefix("o") && (model.dropFirst().first?.isNumber ?? false))
        if let effort, isReasoningModel, effort != "none" || openAIHost {
            body["reasoning_effort"] = effort == "max" ? "high" : effort
        }
        return body
    }

    struct Usage {
        let input: Int
        let cached: Int
        let written: Int
        let output: Int
        let reasoning: Int
        var ordinary: Int { max(0, input - cached - written) }
        var hitPercent: Int { input > 0 ? Int(Double(cached) / Double(input) * 100) : 0 }
        init(_ json: [String: Any]) {
            let details = json["input_tokens_details"] as? [String: Any] ?? [:]
            let out = json["output_tokens_details"] as? [String: Any] ?? [:]
            input = (json["input_tokens"] as? NSNumber)?.intValue ?? 0
            cached = (details["cached_tokens"] as? NSNumber)?.intValue ?? 0
            written = (details["cache_write_tokens"] as? NSNumber)?.intValue ?? 0
            output = (json["output_tokens"] as? NSNumber)?.intValue ?? 0
            reasoning = (out["reasoning_tokens"] as? NSNumber)?.intValue ?? 0
        }
        /// Standard token rates verified 2026-09-07. Excludes tool, audio, and priority charges.
        func estimatedUSD(model: String) -> Double? {
            let rate: (Double, Double)
            switch model {
            case "gpt-5.6-luna": rate = (0.20, 1.20)
            default: return nil
            }
            let inputMultiplier = input > 272_000 ? 2.0 : 1.0
            let outputMultiplier = input > 272_000 ? 1.5 : 1.0
            return ((Double(ordinary) + Double(cached) * 0.1 + Double(written) * 1.25) * rate.0 * inputMultiplier + Double(output) * rate.1 * outputMultiplier) / 1_000_000
        }
    }
}

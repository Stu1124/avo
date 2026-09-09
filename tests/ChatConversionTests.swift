// deps: Avo/Agent/ChatConversion.swift Avo/Agent/RequestPolicy.swift
import Foundation

@main
struct ChatConversionTests {
    static func main() {
        let input: [[String: Any]] = [
            ["role": "user", "content": [["type": "input_text", "text": "hi"], ["type": "input_image", "image_url": "data:image/jpeg;base64,AAAA", "detail": "auto"]]],
            ["role": "assistant", "content": [["type": "output_text", "text": "Checking."]]],
            ["type": "function_call", "call_id": "c1", "name": "list_reminders", "arguments": "{}"],
            ["type": "function_call", "call_id": "c2", "name": "now", "arguments": "{\"tz\":\"x\"}"],
            ["type": "function_call_output", "call_id": "c1", "output": "[]"],
            ["type": "function_call_output", "call_id": "c2", "output": "12:00"],
            ["role": "user", "content": "plain string"]
        ]
        let m = ChatConversion.messages(instructions: "SYS", input: input)
        precondition(m.count == 6, "system + user + assistant(text merged with tool_calls) + 2 tool + user, got \(m.count)")
        precondition(m[0]["role"] as? String == "system" && m[0]["content"] as? String == "SYS")
        let u = m[1]["content"] as! [[String: Any]]
        precondition(u[0]["type"] as? String == "text" && u[0]["text"] as? String == "hi")
        precondition(u[1]["type"] as? String == "image_url" && ((u[1]["image_url"] as! [String: Any])["url"] as? String) == "data:image/jpeg;base64,AAAA")
        precondition(m[2]["role"] as? String == "assistant" && m[2]["content"] as? String == "Checking.")
        let calls = m[2]["tool_calls"] as! [[String: Any]]
        precondition(calls.count == 2, "consecutive function_calls merge into the preceding assistant text message")
        precondition((calls[1]["function"] as! [String: Any])["arguments"] as? String == "{\"tz\":\"x\"}" && calls[1]["id"] as? String == "c2")
        precondition(m[3]["role"] as? String == "tool" && m[3]["tool_call_id"] as? String == "c1" && m[3]["content"] as? String == "[]")
        precondition(m[4]["role"] as? String == "tool" && m[4]["tool_call_id"] as? String == "c2")
        precondition(m[5]["role"] as? String == "user" && m[5]["content"] as? String == "plain string")

        let mergeInput: [[String: Any]] = [
            ["role": "assistant", "content": [["type": "output_text", "text": "Checking."]]],
            ["type": "function_call", "call_id": "c1", "name": "list_reminders", "arguments": "{}"]
        ]
        let merged = ChatConversion.messages(instructions: "SYS", input: mergeInput)
        precondition(merged.count == 2, "system + one merged assistant message, got \(merged.count)")
        precondition(merged[1]["role"] as? String == "assistant" && merged[1]["content"] as? String == "Checking.")
        let mergedCalls = merged[1]["tool_calls"] as! [[String: Any]]
        precondition(mergedCalls.count == 1, "assistant text + one function_call yields one assistant message with one tool call")

        // A reasoning item between two function_calls flushes the first batch; the second must append, not replace.
        let splitInput: [[String: Any]] = [
            ["role": "assistant", "content": [["type": "output_text", "text": "A"]]],
            ["type": "function_call", "call_id": "c1", "name": "now", "arguments": "{}"],
            ["type": "reasoning"],
            ["type": "function_call", "call_id": "c2", "name": "list_reminders", "arguments": "{}"]
        ]
        let split = ChatConversion.messages(instructions: "SYS", input: splitInput)
        precondition(split.count == 2, "system + one merged assistant message, got \(split.count)")
        let splitCalls = split[1]["tool_calls"] as! [[String: Any]]
        precondition(splitCalls.count == 2, "both tool calls survive a flush split, got \(splitCalls.count)")
        precondition(splitCalls[0]["id"] as? String == "c1" && splitCalls[1]["id"] as? String == "c2", "tool calls keep their order")

        let tools = ChatConversion.tools([["type": "function", "name": "now", "description": "d", "parameters": ["type": "object"]], ["type": "web_search"]])
        precondition(tools.count == 1, "web_search is dropped")
        let f = tools[0]["function"] as! [String: Any]
        precondition(tools[0]["type"] as? String == "function" && f["name"] as? String == "now" && f["parameters"] != nil)

        let body = RequestPolicy.chatBody(model: "llama3.2", effort: "low", instructions: "SYS", input: [], tools: tools, stream: true, maxTokens: 500)
        precondition(body["messages"] != nil && body["input"] == nil && body["instructions"] == nil)
        precondition(body["prompt_cache_key"] == nil && body["prompt_cache_options"] == nil && body["text"] == nil)
        precondition((body["stream_options"] as? [String: Bool]) == ["include_usage": true])
        precondition(body["reasoning_effort"] == nil, "effort only sent for gpt-5*/o* models")
        precondition(body["max_tokens"] as? Int == 500 && body["max_completion_tokens"] == nil,
                     "third-party servers get max_tokens")
        let openAI = RequestPolicy.chatBody(model: "gpt-5.6-luna", effort: nil, instructions: "S", input: [], tools: [], stream: false, maxTokens: 42, openAIHost: true)
        precondition(openAI["max_completion_tokens"] as? Int == 42 && openAI["max_tokens"] == nil,
                     "OpenAI rejects max_tokens on its newer models")
        let noneOpenAI = RequestPolicy.chatBody(model: "gpt-5.6-luna", effort: "none", instructions: "S", input: [], tools: tools, stream: false, maxTokens: 10, openAIHost: true)
        precondition(noneOpenAI["reasoning_effort"] as? String == "none",
                     "OpenAI needs an explicit effort to allow function tools on a reasoning model")
        let noneLocal = RequestPolicy.chatBody(model: "gpt-5-local", effort: "none", instructions: "S", input: [], tools: tools, stream: false, maxTokens: 10)
        precondition(noneLocal["reasoning_effort"] == nil, "third-party servers still get no effort key")
        let gpt = RequestPolicy.chatBody(model: "gpt-5.4-mini", effort: "max", instructions: "S", input: [], tools: [], stream: false, maxTokens: 10)
        precondition(gpt["reasoning_effort"] as? String == "high" && gpt["stream_options"] == nil && gpt["tools"] == nil)

        let orca = RequestPolicy.chatBody(model: "orca-mini", effort: "low", instructions: "S", input: [], tools: [], stream: false, maxTokens: 10)
        precondition(orca["reasoning_effort"] == nil, "\"o\" followed by a non-digit is not a reasoning model")
        let o3 = RequestPolicy.chatBody(model: "o3", effort: "low", instructions: "S", input: [], tools: [], stream: false, maxTokens: 10)
        precondition(o3["reasoning_effort"] as? String == "low", "\"o\" followed by a digit is a reasoning model")
        print("PASS: chat message conversion, tool wrapping, chat body gating")
    }
}

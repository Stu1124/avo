import Foundation

/// Converts Responses-API-shaped input items and tool definitions into chat-completions shapes.
enum ChatConversion {
    static func messages(instructions: String, input: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": instructions]]
        var pendingCalls: [[String: Any]] = []
        func flushCalls() {
            guard !pendingCalls.isEmpty else { return }
            if let last = out.last, last["role"] as? String == "assistant", last["content"] is String {
                var merged = last
                merged["tool_calls"] = (last["tool_calls"] as? [[String: Any]] ?? []) + pendingCalls
                out[out.count - 1] = merged
            } else {
                out.append(["role": "assistant", "content": NSNull(), "tool_calls": pendingCalls])
            }
            pendingCalls = []
        }
        for item in input {
            if let type = item["type"] as? String, type == "function_call" {
                let callId = item["call_id"] as? String ?? UUID().uuidString
                pendingCalls.append(["id": callId, "type": "function",
                                     "function": ["name": item["name"] as? String ?? "", "arguments": item["arguments"] as? String ?? "{}"]])
                continue
            }
            flushCalls()
            if let type = item["type"] as? String, type == "function_call_output" {
                out.append(["role": "tool", "tool_call_id": item["call_id"] as? String ?? "", "content": item["output"] as? String ?? ""])
                continue
            }
            guard let roleRaw = item["role"] as? String else { continue }
            let role = (roleRaw == "developer") ? "system" : roleRaw
            if let text = item["content"] as? String {
                out.append(["role": role, "content": text]); continue
            }
            let parts = item["content"] as? [[String: Any]] ?? []
            if role == "assistant" {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                out.append(["role": "assistant", "content": text]); continue
            }
            var chatParts: [[String: Any]] = []
            for p in parts {
                switch p["type"] as? String {
                case "input_text", "output_text", "text": chatParts.append(["type": "text", "text": p["text"] as? String ?? ""])
                case "input_image": if let url = p["image_url"] as? String { chatParts.append(["type": "image_url", "image_url": ["url": url]]) }
                default: break
                }
            }
            out.append(["role": role, "content": chatParts])
        }
        flushCalls()
        return out
    }

    static func tools(_ responsesTools: [[String: Any]]) -> [[String: Any]] {
        responsesTools.compactMap { t in
            guard t["type"] as? String == "function", let name = t["name"] as? String else { return nil }
            var f: [String: Any] = ["name": name]
            if let d = t["description"] { f["description"] = d }
            if let p = t["parameters"] { f["parameters"] = p }
            return ["type": "function", "function": f]
        }
    }
}

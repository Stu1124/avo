import Foundation

/// OpenAI-compatible chat-completions client (Ollama, LM Studio, OpenRouter, Groq, xAI, Anthropic compat).
final class ChatCompletionsClient: BrainClient {
    private let sse = SSESession()

    @MainActor
    func stream(model: String, effort: String?, instructions: String, input: [[String: Any]], tools: [[String: Any]]) -> AsyncStream<BrainEvent> {
        let s = Settings.shared
        // A local server (Ollama, LM Studio) needs no key; a hosted OpenAI-compatible endpoint does,
        // and saying so beats letting the provider answer 401 with its own wording.
        if s.isOpenAIHost, (s.apiKey ?? "").isEmpty {
            return AsyncStream { c in c.yield(.error("API key missing. Add it in Settings → General → Model.")); c.finish() }
        }
        let body = RequestPolicy.chatBody(model: model, effort: effort, instructions: instructions, input: input,
                                          tools: ChatConversion.tools(tools), stream: true,
                                          maxTokens: effort == "none" ? 4096 : 16384, openAIHost: s.isOpenAIHost)
        return sse.stream(Self.request(path: "chat/completions", body: body, stream: true), parser: ChatSSEParser(), providerLabel: URL(string: s.apiBaseURL)?.host ?? "Provider")
    }

    @MainActor
    func complete(model: String, instructions: String, prompt: String, maxTokens: Int) async -> String? {
        let body = RequestPolicy.chatBody(model: model, effort: nil, instructions: instructions,
                                          input: [["role": "user", "content": prompt]], tools: [], stream: false,
                                          maxTokens: maxTokens, openAIHost: Settings.shared.isOpenAIHost)
        guard let (data, response) = try? await URLSession.shared.data(for: Self.request(path: "chat/completions", body: body, stream: false)),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    @MainActor
    private static func request(path: String, body: [String: Any], stream: Bool) -> URLRequest {
        let s = Settings.shared
        var req = URLRequest(url: ProviderURL.endpoint(path, base: s.apiBaseURL))
        req.httpMethod = "POST"
        if let key = s.apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }
}

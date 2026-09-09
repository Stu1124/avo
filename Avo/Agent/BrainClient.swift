import Foundation

/// One normalised event from any brain provider. Every client yields this same stream to AgentRuntime.
enum BrainEvent {
    case textDelta(String)
    case toolCall(id: String, callId: String, name: String, arguments: String)
    case reasoningSummary(String)
    case webSearchStarted
    case citation(title: String, url: String)
    case completed(responseId: String, usage: [String: Any]?)
    case error(String)
}

/// The model backend behind a turn: a streaming call plus a small non-streaming helper.
protocol BrainClient: AnyObject {
    @MainActor func stream(model: String, effort: String?, instructions: String, input: [[String: Any]], tools: [[String: Any]]) -> AsyncStream<BrainEvent>
    @MainActor func complete(model: String, instructions: String, prompt: String, maxTokens: Int) async -> String?
}

/// Provider-specific decoding of a server-sent-events stream into `BrainEvent`s.
protocol SSEEventParser {
    mutating func feed(_ eventBlock: Data) -> [BrainEvent]   // one block between blank lines
    mutating func finish() -> [BrainEvent]                    // called once after the last block
}

/// Builds the provider URL from the configured base, tolerating a trailing slash and a missing "/v1".
enum ProviderURL {
    static func endpoint(_ path: String, base: String) -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        // A bare host — "https://api.openai.com" — is the API root left off, not a provider that
        // serves the API at "/": every OpenAI-compatible server Avo talks to mounts it at /v1.
        // A base that already has a path ("…/api/v1", "…/openai/v1") is taken as given.
        if let u = URL(string: b), u.host != nil, u.path.isEmpty || u.path == "/" { b += "/v1" }
        return URL(string: b + "/" + path) ?? URL(string: "https://api.openai.com/v1/" + path)!
    }
}

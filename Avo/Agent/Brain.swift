import Foundation

enum BrainStyle: String { case responses, chat, foundation }

/// Chooses the BrainClient for the configured provider style.
enum Brain {
    @MainActor private static var cache: [BrainStyle: BrainClient] = [:]

    @MainActor static var style: BrainStyle {
        let s = Settings.shared
        guard let st = BrainStyle(rawValue: s.apiStyle) else { return .chat }
        if st == .responses && !s.isOpenAIHost { return .chat }
        return st
    }

    @MainActor static func client() -> BrainClient {
        let st = style
        if let c = cache[st] { return c }
        let c: BrainClient
        switch st {
        case .responses: c = ResponsesClient()
        case .chat: c = ChatCompletionsClient()
        // `.foundation` is reserved for an on-device model and currently maps to the chat client.
        case .foundation: c = ChatCompletionsClient()
        }
        cache[st] = c
        return c
    }

    @MainActor static var voiceModeAvailable: Bool {
        let s = Settings.shared
        return style == .responses && s.isOpenAIHost && !(s.apiKey ?? "").isEmpty
    }
}

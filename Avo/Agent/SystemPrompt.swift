import Foundation

/// Loads persona settings, the user's context files, and memory, then hands them to `SystemPromptRender`.
/// The result must stay byte-identical across turns so the provider's automatic prompt cache covers it plus
/// the resent conversation history; per-turn context belongs in the user message (see `ContextBuilder.render`),
/// not here — anything dynamic here breaks the cache prefix. The cache key is the persona settings plus the
/// files' modification stamps, so a changed file is picked up without a relaunch.
@MainActor
enum SystemPrompt {
    private static var cache: [String: String] = [:]

    /// - Parameters:
    ///   - includeVoice: the writing rules are only worth sending when the request is about writing something.
    ///   - compact: drops the user's context files, for budget-constrained callers such as realtime voice mode.
    ///     Memory is always kept.
    static func build(includeVoice: Bool = true, compact: Bool = false) -> String {
        let s = Settings.shared
        let paths = compact ? [] : s.contextFiles
        let files = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let stamps = (files + [Paths.memoryFile]).map {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        }
        // Keyed by the writing style itself, not its hash: a collision would serve a stale prompt for the
        // rest of the session, and the string is a few hundred bytes.
        let key = "\(includeVoice)|\(compact)|\(s.userName)|\(s.writingStyle)|\(paths.joined(separator: ","))|\(stamps)"
        if let cached = cache[key] { return cached }
        let contexts = files.compactMap { url -> (name: String, text: String)? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.lastPathComponent, text)
        }
        let memory = (try? String(contentsOf: Paths.memoryFile, encoding: .utf8)) ?? ""
        let text = SystemPromptRender.render(userName: s.userName, writingStyle: s.writingStyle,
                                             contexts: contexts, memory: memory, includeVoice: includeVoice)
        if cache.count > 8 { cache.removeAll() }  // stamps change over time; keep the map from growing.
        cache[key] = text
        return text
    }
}

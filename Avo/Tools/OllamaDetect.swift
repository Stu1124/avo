import Foundation

/// Probes an already-running Ollama server. Returns model names, or nil when nothing answers within 2 s.
/// One GET to /api/tags and nothing else: this never launches, installs, pulls or starts anything.
enum OllamaDetect {
    static let defaultBase = "http://localhost:11434/v1"

    static func models(at base: String = defaultBase) async -> [String]? {
        guard var comps = URLComponents(string: base) else { return nil }
        comps.path = "/api/tags"
        comps.query = nil
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }
}

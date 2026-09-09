import Foundation

/// Turns "my blog" / "avo" / "~/Developer/foo" into a project folder under the user's home.
enum ProjectResolver {
    struct Match: Equatable {
        var path: String
        var name: String
        var score: Double
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let preferredRoots = ["Documents", "Developer", "Projects", "Code", "Sites"]
    private static let skipNames: Set<String> = ["Library", "node_modules", "Pictures", "Movies", "Music", "Applications", "Public",
                                                 "DerivedData", "build", "dist", "target", "Pods", "venv", ".venv", "__pycache__"]
    private static let recentKey = "codingRecentProjects"
    private static let lock = NSLock()
    private static var cache: (at: Date, dirs: [String])?

    // MARK: recent

    static var recent: [String] {
        (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func remember(_ path: String) {
        var r = recent.filter { $0 != path }
        r.insert(path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(12)), forKey: recentKey)
    }

    // MARK: resolve

    /// Best match for a path or fuzzy name. nil when nothing plausible.
    static func resolve(_ query: String) -> Match? {
        candidates(query, limit: 1).first
    }

    static func candidates(_ rawQuery: String, limit: Int = 5) -> [Match] {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // Explicit path
        let expanded = (q as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                let std = URL(fileURLWithPath: expanded).standardizedFileURL.path
                return [Match(path: std, name: (std as NSString).lastPathComponent, score: 100)]
            }
            // A path that doesn't exist: fall through to fuzzy on its last component.
        }

        let qTokens = tokens(q)
        guard !qTokens.isEmpty else { return [] }
        let qJoined = qTokens.joined()
        let recents = recent

        var scored: [Match] = []
        for dir in allDirectories() {
            let name = (dir as NSString).lastPathComponent
            let s = score(queryTokens: qTokens, queryJoined: qJoined, name: name, path: dir, recents: recents)
            if s > 0 { scored.append(Match(path: dir, name: name, score: s)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.path.count < b.path.count }
        // Require a real match, not just a weak root bonus.
        return Array(scored.filter { $0.score >= 0.45 }.prefix(limit))
    }

    // MARK: scoring

    private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func score(queryTokens qt: [String], queryJoined qj: String, name: String, path: String, recents: [String]) -> Double {
        let nt = tokens(name)
        guard !nt.isEmpty else { return 0 }
        let nj = nt.joined()
        var s = 0.0
        if nj == qj { s = 1.0 }
        else {
            // token overlap (each query token matches a name token exactly or as a prefix)
            var hits = 0.0
            for t in qt {
                if nt.contains(t) { hits += 1 }
                else if nt.contains(where: { $0.hasPrefix(t) && t.count >= 3 }) { hits += 0.8 }
                else if nj.contains(t) && t.count >= 4 { hits += 0.5 }
            }
            let overlap = hits / Double(qt.count)
            let coverage = hits / Double(max(nt.count, 1))
            s = overlap * 0.75 + coverage * 0.25
            if nj.hasPrefix(qj) { s = max(s, 0.7) }
            if overlap < 0.5 { s = 0 }
        }
        guard s > 0 else { return 0 }
        // Location preference
        let rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        if rel.hasPrefix("Developer/") || rel.hasPrefix("Projects/") || rel.hasPrefix("Code/") { s += 0.25 }
        else if rel.hasPrefix("Documents/") || rel.hasPrefix("Sites/") { s += 0.15 }
        let depth = rel.split(separator: "/").count
        s -= Double(max(depth - 2, 0)) * 0.03
        if let i = recents.firstIndex(of: path) { s += 0.2 - Double(i) * 0.01 }
        return s
    }

    // MARK: scan

    /// Directories under ~ up to depth 4, skipping Library / node_modules / .git / hidden. Cached for 2 minutes.
    private static func allDirectories() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, Date().timeIntervalSince(c.at) < 120 { return c.dirs }
        var dirs: [String] = []
        let fm = FileManager.default
        let root = URL(fileURLWithPath: home)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e {
                let vals = try? url.resourceValues(forKeys: Set(keys))
                guard vals?.isDirectory == true else { continue }
                let name = url.lastPathComponent
                if name.hasPrefix(".") || skipNames.contains(name) || vals?.isSymbolicLink == true || vals?.isPackage == true {
                    e.skipDescendants(); continue
                }
                dirs.append(url.path)
                if e.level >= 4 { e.skipDescendants() }
            }
        }
        cache = (Date(), dirs)
        return dirs
    }

    /// Human-friendly short form for cards.
    static func displayName(_ path: String) -> String { (path as NSString).lastPathComponent }
    static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

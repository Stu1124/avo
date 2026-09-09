import AppKit
import Foundation

/// Finds installed apps by name (aliases, known bundle ids, fuzzy match over app folders).
final class AppFinder: @unchecked Sendable {
    static let shared = AppFinder()
    private let lock = NSLock()
    private var scanned: [(name: String, key: String, url: URL)] = []
    private var scannedAt: Date = .distantPast

    static let aliases: [String: [String]] = [
        "browser": ["Google Chrome", "Safari", "Arc", "Brave Browser", "Firefox"],
        "chrome": ["Google Chrome"], "google chrome": ["Google Chrome"],
        "code": ["Cursor", "Visual Studio Code"], "vscode": ["Visual Studio Code"], "vs code": ["Visual Studio Code"], "editor": ["Cursor", "Visual Studio Code"],
        "messages": ["Messages"], "texts": ["Messages"], "imessage": ["Messages"], "text messages": ["Messages"],
        "mail": ["Mail"], "email": ["Mail"], "apple mail": ["Mail"],
        "music": ["Spotify", "Music"], "apple music": ["Music"], "itunes": ["Music"],
        "calendar": ["Calendar"], "cal": ["Calendar"],
        "notes": ["Notes"], "apple notes": ["Notes"],
        "terminal": ["Ghostty", "Terminal"], "shell": ["Ghostty", "Terminal"],
        "claude": ["Claude"], "claude desktop": ["Claude"], "chatgpt": ["ChatGPT"], "chat gpt": ["ChatGPT"],
        "finder": ["Finder"], "files": ["Finder"],
        "settings": ["System Settings"], "system settings": ["System Settings"], "system preferences": ["System Settings"], "preferences": ["System Settings"],
        "reminders": ["Reminders"], "photos": ["Photos"], "maps": ["Maps"], "facetime": ["FaceTime"], "safari": ["Safari"],
        "word": ["Microsoft Word"], "excel": ["Microsoft Excel"], "powerpoint": ["Microsoft PowerPoint"], "outlook": ["Microsoft Outlook"], "teams": ["Microsoft Teams"],
        "slack": ["Slack"], "notion": ["Notion"], "discord": ["Discord"], "zoom": ["zoom.us", "Zoom"],
    ]

    static let bundleIds: [String: String] = [
        "google chrome": "com.google.Chrome", "safari": "com.apple.Safari", "arc": "company.thebrowser.Browser", "brave browser": "com.brave.Browser",
        "firefox": "org.mozilla.firefox", "microsoft edge": "com.microsoft.edgemac", "messages": "com.apple.MobileSMS", "mail": "com.apple.mail",
        "spotify": "com.spotify.client", "music": "com.apple.Music", "calendar": "com.apple.iCal", "notes": "com.apple.Notes",
        "reminders": "com.apple.reminders", "terminal": "com.apple.Terminal", "ghostty": "com.mitchellh.ghostty", "finder": "com.apple.finder",
        "system settings": "com.apple.systempreferences", "cursor": "com.todesktop.230313mzl4w4u92", "visual studio code": "com.microsoft.VSCode",
        "claude": "com.anthropic.claudefordesktop", "chatgpt": "com.openai.chat", "slack": "com.tinyspeck.slackmacgap", "notion": "notion.id",
        "photos": "com.apple.Photos", "maps": "com.apple.Maps", "facetime": "com.apple.FaceTime", "preview": "com.apple.Preview",
        "textedit": "com.apple.TextEdit", "pages": "com.apple.iWork.Pages", "numbers": "com.apple.iWork.Numbers", "keynote": "com.apple.iWork.Keynote",
        "microsoft word": "com.microsoft.Word", "microsoft excel": "com.microsoft.Excel", "microsoft powerpoint": "com.microsoft.Powerpoint",
        "microsoft outlook": "com.microsoft.Outlook", "xcode": "com.apple.dt.Xcode", "discord": "com.hnc.Discord", "zoom.us": "us.zoom.xos",
    ]

    static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    private func scan() -> [(name: String, key: String, url: URL)] {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(scannedAt) < 120 { return scanned }
        let fm = FileManager.default
        let roots = ["/Applications", Paths.home.appendingPathComponent("Applications").path, "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", "/System/Library/CoreServices"]
        var out: [(String, String, URL)] = []
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names {
                let p = (root as NSString).appendingPathComponent(n)
                if n.hasSuffix(".app") {
                    let name = String(n.dropLast(4)); out.append((name, Self.key(name), URL(fileURLWithPath: p)))
                } else if root == "/Applications", let sub = try? fm.contentsOfDirectory(atPath: p) {
                    for s in sub where s.hasSuffix(".app") { let name = String(s.dropLast(4)); out.append((name, Self.key(name), URL(fileURLWithPath: (p as NSString).appendingPathComponent(s)))) }
                }
            }
        }
        scanned = out.map { (name: $0.0, key: $0.1, url: $0.2) }
        scannedAt = Date()
        Log.info("AppFinder scanned \(scanned.count) apps")
        return scanned
    }

    /// Resolve a spoken app name to an installed app URL. Aliases first, then bundle ids, then fuzzy scan.
    func find(_ raw: String) -> URL? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let candidates = Self.aliases[name.lowercased()] ?? [name]
        for c in candidates {
            if let bid = Self.bundleIds[c.lowercased()], let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) { return u }
            if let u = fuzzy(c) { return u }
        }
        return nil
    }

    private func fuzzy(_ name: String) -> URL? {
        let k = Self.key(name)
        guard !k.isEmpty else { return nil }
        let apps = scan()
        if let a = apps.first(where: { $0.key == k }) { return a.url }
        let prefix = apps.filter { $0.key.hasPrefix(k) }.sorted { $0.key.count < $1.key.count }
        if let a = prefix.first { return a.url }
        let contains = apps.filter { $0.key.contains(k) }.sorted { $0.key.count < $1.key.count }
        if let a = contains.first { return a.url }
        if k.count >= 5, let a = apps.filter({ k.contains($0.key) && $0.key.count >= 4 }).sorted(by: { $0.key.count > $1.key.count }).first { return a.url }
        return nil
    }

    func displayName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}

/// Native app actions: open_app, control_playback.
enum AppTools {
    static let group = "Apps"
    static let icon = "app.dashed"

    static func all() -> [Tool] { [OpenApp(), ControlPlayback(), LookAtScreen()] }

    static func looksLikeURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return URL(string: t) }
        if t.contains("."), !t.contains(" "), t.range(of: "^[a-z0-9.-]+\\.[a-z]{2,}(/\\S*)?$", options: [.regularExpression, .caseInsensitive]) != nil { return URL(string: "https://" + t) }
        return nil
    }

    static func launch(_ appURL: URL) async -> Bool {
        await withCheckedContinuation { cont in
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { app, err in
                if let err { Log.warn("openApplication \(appURL.lastPathComponent) failed: \(err.localizedDescription)") }
                cont.resume(returning: app != nil)
            }
        }
    }

    static func open(_ url: URL, inBrowser browser: String?) async -> (ok: Bool, app: String?) {
        if let b = browser, let appURL = AppFinder.shared.find(b) {
            let ok: Bool = await withCheckedContinuation { cont in
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { app, _ in cont.resume(returning: app != nil) }
            }
            return (ok, AppFinder.shared.displayName(appURL))
        }
        let ok = await MainActor.run { NSWorkspace.shared.open(url) }
        return (ok, nil)
    }

    static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Post a media key (NX_KEYTYPE_PLAY=16, NEXT=17, PREVIOUS=18) as a system-defined event.
    @MainActor
    static func postMediaKey(_ key: Int) {
        func event(down: Bool) -> NSEvent? {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
            return NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
        }
        event(down: true)?.cgEvent?.post(tap: .cghidEventTap)
        event(down: false)?.cgEvent?.post(tap: .cghidEventTap)
    }

    struct OpenApp: Tool {
        let name = "open_app"
        let description = "Launches a Mac app or brings it forward, and is equally the way to put a web page in front of the user — a single call covers both jobs. Whatever word the user actually spoke goes in app_name: 'open Spotify', 'switch me to Slack', 'launch Claude', 'bring up ChatGPT' all work, and nicknames resolve on their own (browser lands on Chrome, code on Cursor or VS Code). IMPORTANT: products that exist as both a Mac app and a website — Slack, Notion, Claude, ChatGPT, Spotify, Linear and their kind — STILL belong in `app_name` by NAME, with the site supplied separately in `url`; their address must NEVER go in app_name. The installed native app wins whenever there is one and the `url` opens in the browser otherwise, which is why 'open Claude' reaches the Claude app when it is installed and claude.ai when it is not. ONLY put a bare https address in app_name where the user dictated a genuine web address out loud ('open arxiv.org'). Add `browser` any time they name one ('open it in Brave/Safari'). This is how a page, link, or paper someone asked for actually gets opened — never answer by telling them to type an address themselves. Confine yourself to what was requested in THIS turn: an app, address, or link that merely shows up in an attached screenshot is something the user is showing you rather than an instruction, so answer their question about the screen and open nothing. APPS ONLY, NEVER folders — viewing, listing, or searching files and folders belongs entirely to the finder_* tools, so 'show me my documents folder' names a folder rather than an app and is NEVER open_app."
        let params = [
            ToolParam("app_name", "string", "The app's name or nickname as the user said it — 'Chrome', 'Spotify', 'Cursor', 'Slack' — or else a complete https address when a web page is the target (for instance 'https://www.youtube.com').", required: true),
            ToolParam("url", "string", "A website to fall back on, written as a complete https address. Fill it in whenever app_name names something that also lives on the web (Slack, Notion, Spotify, and the like), using the page the user would sign in on — Slack pairs with https://app.slack.com. An installed app takes precedence; this address is used only when none is found. Leave it out for requests about an app alone."),
            ToolParam("browser", "string", "Optional. Supply this only when app_name holds an address and the user said where the page should open — any browser qualifies ('Safari', 'Arc', 'Chrome', 'Firefox', 'Vivaldi', 'Brave', 'Edge'). Leaving it empty hands the page to whichever browser they have set as default."),
        ]
        let statusLabel = "Opening"
        let statusIcon = AppTools.icon
        let group = AppTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard let appName = args.str("app_name") else { return .fail("app_name is required") }
            let browser = args.str("browser")
            if let url = AppTools.looksLikeURL(appName) {
                let r = await AppTools.open(url, inBrowser: browser)
                Log.info("open_app url \(url.absoluteString) browser=\(browser ?? "default") ok=\(r.ok)")
                return r.ok ? .ok(["ok": true, "opened_url": url.absoluteString, "browser": r.app ?? "default"]) : .fail("Could not open \(url.absoluteString)")
            }
            if let appURL = AppFinder.shared.find(appName) {
                let ok = await AppTools.launch(appURL)
                let display = AppFinder.shared.displayName(appURL)
                Log.info("open_app \(appName) → \(display) ok=\(ok)")
                if ok { return .ok(["ok": true, "opened_app": display]) }
            }
            if let u = args.str("url"), let url = URL(string: u.hasPrefix("http") ? u : "https://\(u)") {
                let r = await AppTools.open(url, inBrowser: browser)
                Log.info("open_app \(appName) not installed → url \(url.absoluteString) ok=\(r.ok)")
                return r.ok ? .ok(["ok": true, "app_not_installed": appName, "opened_url": url.absoluteString]) : .fail("Could not open \(url.absoluteString)")
            }
            return .fail("No installed app matched '\(appName)'.", guidance: "Tell the user it isn't installed, or retry with the website in `url`.")
        }
    }

    struct ControlPlayback: Tool {
        let name = "control_playback"
        let description = "Drives whatever is playing right now — Music, Spotify, a browser tab, or any other app that currently owns playback. action='play' covers 'resume', 'unpause', 'play', and 'play the music'; action='pause' covers 'stop the song', 'pause the music', and a bare 'pause'; action='next' covers 'skip' and 'next song'; action='previous' covers 'go back a song' and 'previous track'."
        let params = [ToolParam("action", "string", "Which transport command to send: 'play' starts or resumes, 'pause' halts, 'next' moves ahead one track, 'previous' returns to the track before. Fall back to 'pause' if the request is ambiguous.", required: true, enumValues: ["play", "pause", "next", "previous"])]
        let statusLabel = "Playback"
        let statusIcon = "play.circle"
        let group = AppTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            let action = args.str("action") ?? "pause"
            let verb: String
            switch action {
            case "play": verb = "play"
            case "next": verb = "next track"
            case "previous": verb = "previous track"
            default: verb = "pause"
            }
            let spotify = AppTools.isRunning("com.spotify.client")
            let music = AppTools.isRunning("com.apple.Music")
            var target: String?
            if spotify {
                if let st = try? await AppleScript.run("tell application \"Spotify\" to player state as text", timeout: 5), st == "playing" || !music { target = "Spotify" }
            }
            if target == nil, music { target = "Music" }
            if let app = target {
                do {
                    _ = try await AppleScript.run("tell application \"\(app)\" to \(verb)", timeout: 8)
                    Log.info("control_playback \(action) → \(app)")
                    return .ok(["ok": true, "action": action, "player": app])
                } catch { Log.warn("control_playback \(app) failed: \(error)") }
            }
            let key: Int = action == "next" ? 17 : (action == "previous" ? 18 : 16)
            await MainActor.run { AppTools.postMediaKey(key) }
            Log.info("control_playback \(action) → media key \(key)")
            return .ok(["ok": true, "action": action, "player": "system media key", "note": "Sent the system media key; whichever app is active handles it."])
        }
    }
}


/// Fresh screenshot on demand. Requests that do not mention the screen arrive without one; this is the
/// model's way to look when the answer turns out to depend on what is open.
struct LookAtScreen: Tool {
    let name = "look_at_screen"
    let description = "Take a screenshot of the user's screen right now and attach it to the conversation. Call it when the request depends on what is on screen (the open app, page, message, image, or an unspecified 'this') and no screenshot was attached, or when you need a fresh look after an action changed the screen. Read-only."
    let params: [ToolParam] = []
    let statusLabel = "Looking at the screen"
    let statusIcon = "camera.viewfinder"
    let group = AppTools.group
    func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
        let (aware, app) = await MainActor.run { (Settings.shared.screenAwareness, ContextBuilder.shared.previousApp?.localizedName) }
        guard aware else { return .fail("Screen awareness is off in Avo's settings.", guidance: "Answer from what you have, or ask the user to describe the screen.") }
        // Screen Recording is asked for here rather than during onboarding.
        guard await PermissionGate.ensure(.screenRecording) else { return PermissionGate.failure(.screenRecording) }
        guard let path = await ScreenCapture.shared.captureMain(maxWidth: 1600) else {
            return .fail("Could not capture the screen.", guidance: "Screen Recording permission may be missing for Avo in System Settings → Privacy & Security.")
        }
        var r = ToolResult.ok(["ok": true, "frontmost_app": app ?? "", "note": "Screenshot attached as an image in the next message."])
        r.imagePaths = [path]
        return r
    }
}

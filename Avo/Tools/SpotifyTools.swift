import AppKit
import Foundation

/// Spotify desktop control through its AppleScript dictionary.
enum Spotify {
    static let bundleId = "com.spotify.client"
    static let icon = "app:com.spotify.client"
    static let notInstalled = "Spotify is not installed."

    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil }
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }

    /// Launch Spotify if needed (without stealing focus) and wait until it answers AppleScript.
    static func ensureRunning() async -> Bool {
        guard installed else { return false }
        if running { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
        let launched: Bool = await withCheckedContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in cont.resume(returning: app != nil) }
        }
        guard launched else { return false }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if (try? await tell("player state as text", timeout: 4)) != nil { return true }
        }
        return running
    }

    static func tell(_ body: String, timeout: TimeInterval = 10) async throws -> String {
        try await AppleScript.run("tell application \"Spotify\"\n\(body)\nend tell", timeout: timeout)
    }

    struct State {
        var state: String; var volume: Int; var shuffle: Bool; var repeating: Bool
        var track: String?; var artist: String?; var album: String?; var durationMs: Int?; var positionSec: Double?; var id: String?
        var json: [String: Any] {
            var j: [String: Any] = ["state": state, "volume": volume, "shuffle": shuffle, "repeat": repeating]
            if let t = track { j["track"] = t }
            if let a = artist { j["artist"] = a }
            if let a = album { j["album"] = a }
            if let d = durationMs { j["duration"] = clock(Double(d) / 1000) }
            if let p = positionSec { j["position"] = clock(p) }
            if let i = id { j["uri"] = i }
            return j
        }
    }

    static func clock(_ s: Double) -> String { let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60) }

    static func state() async throws -> State {
        let out = try await tell("""
            set s1 to (player state as text)
            set v1 to sound volume
            set h1 to shuffling
            set r1 to repeating
            try
                set t to current track
                set p1 to player position
                return s1 & "|||" & v1 & "|||" & h1 & "|||" & r1 & "|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (duration of t) & "|||" & p1 & "|||" & (id of t)
            on error
                return s1 & "|||" & v1 & "|||" & h1 & "|||" & r1
            end try
            """)
        let p = out.components(separatedBy: "|||")
        guard p.count >= 4 else { throw AppleScript.Failure(message: "Unexpected Spotify reply: \(out)") }
        var s = State(state: p[0], volume: Int(p[1]) ?? 0, shuffle: p[2] == "true", repeating: p[3] == "true")
        if p.count >= 10 {
            s.track = p[4]; s.artist = p[5]; s.album = p[6]; s.durationMs = Int(p[7]); s.positionSec = Double(p[8].replacingOccurrences(of: ",", with: ".")); s.id = p[9]
        }
        return s
    }

    static func card(_ s: State, title: String? = nil) -> CardKind {
        var blocks: [GlanceCard.Block] = []
        if let t = s.track {
            blocks.append(.header(title: title ?? t, subtitle: title == nil ? [s.artist, s.album].compactMap { $0 }.joined(separator: " · ") : "\(t) · \(s.artist ?? "")", icon: icon))
            if let d = s.durationMs, let pos = s.positionSec, d > 0 {
                blocks.append(.progress(value: pos, max: Double(d) / 1000, label: "\(clock(pos)) / \(clock(Double(d) / 1000))"))
            }
        } else {
            blocks.append(.header(title: title ?? "Spotify", subtitle: s.state.capitalized, icon: icon))
        }
        var badges: [GlanceCard.Badge] = [.init(text: s.state.capitalized, tone: s.state == "playing" ? .good : .neutral), .init(text: "Vol \(s.volume)")]
        if s.shuffle { badges.append(.init(text: "Shuffle", tone: .accent)) }
        if s.repeating { badges.append(.init(text: "Repeat", tone: .accent)) }
        blocks.append(.badges(badges))
        return .glance(GlanceCard(id: UUID(), blocks: blocks, source: "Spotify", sourceIcon: icon))
    }

    /// Normalise an open.spotify.com link or bare id into a spotify: URI.
    static func uri(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("spotify:") { return s }
        if let u = URL(string: s), let host = u.host, host.contains("spotify.com") {
            let parts = u.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 { return "spotify:\(parts[parts.count - 2]):\(parts[parts.count - 1])" }
        }
        return nil
    }

    /// After a command, re-read state and package it for the model.
    static func result(_ extra: [String: Any] = [:], title: String? = nil) async -> ToolResult {
        do {
            let s = try await state()
            var j = s.json; j["ok"] = true
            for (k, v) in extra { j[k] = v }
            return .ok(j, cards: [card(s, title: title)])
        } catch {
            var j: [String: Any] = ["ok": true]; for (k, v) in extra { j[k] = v }
            return .ok(j)
        }
    }

    static func failure(_ e: Error) -> ToolResult {
        .fail("Spotify error: \(e)", guidance: "If macOS asked for Automation permission, tell the user to allow Avo to control Spotify, then retry.")
    }
}

enum SpotifyTools {
    static let group = "Spotify"
    static let icon = Spotify.icon

    static func all() -> [Tool] { [Play(), Pause(), Next(), Previous(), NowPlaying(), SetVolume(), Shuffle(), Repeat()] }

    static func precheck(launch: Bool = true) async -> ToolResult? {
        guard Spotify.installed else { return .fail(Spotify.notInstalled, guidance: "Offer control_playback or open_app instead.") }
        if launch, !(await Spotify.ensureRunning()) { return .fail("Spotify did not start.", guidance: "Ask the user to open Spotify, then retry.") }
        return nil
    }

    struct Play: Tool {
        let name = "spotify_play"
        let description = "Play music in the Spotify desktop app: a track, album, artist or playlist by name, a specific Spotify URI/link, or resume the current track when called with nothing. Use for 'play some Radiohead', 'play the album Blonde', 'put on my Focus playlist', 'resume'. When a name is given without a URI, Avo opens Spotify's search for it and starts playback of the top result when possible."
        let params = [
            ToolParam("query", "string", "What to look up and start playing — a song ('Bohemian Rhapsody by Queen'), an artist ('Taylor Swift'), or the title of a playlist. Naming the artist alongside a song title sharpens the match. Omit it entirely when resuming, or when `uri` already identifies the item."),
            ToolParam("type", "string", "Tells Spotify which sort of item `query` names; 'track' is assumed when nothing is passed. Pick 'album' when the user says to play an album, 'artist' when they ask for some artist's music generally, and 'playlist' when they call a playlist by name.", enumValues: ["track", "album", "artist", "playlist"]),
            ToolParam("uri", "string", "An exact Spotify identifier — either a URI in the 'spotify:track:...' or 'spotify:playlist:...' form, or a share link from open.spotify.com. Reach for this field whenever the precise link is already in hand, instead of searching by name."),
        ]
        let statusLabel = "Playing"
        let statusIcon = SpotifyTools.icon
        let group = SpotifyTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            if let f = await SpotifyTools.precheck() { return f }
            if let raw = args.str("uri") {
                guard let uri = Spotify.uri(from: raw) else { return .fail("Not a Spotify URI or link: \(raw)") }
                do {
                    _ = try await Spotify.tell("play track \(AppleScript.quote(uri))")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    Log.info("spotify_play uri \(uri)")
                    return await Spotify.result(["played": uri], title: "Playing")
                } catch { return Spotify.failure(error) }
            }
            guard let q = args.str("query") else {
                do { _ = try await Spotify.tell("play"); Log.info("spotify_play resume"); return await Spotify.result(["resumed": true], title: "Playing") }
                catch { return Spotify.failure(error) }
            }
            // No public search without auth: open Spotify's search view for the query, then try to play the top result via UI scripting.
            let type = args.str("type") ?? "track"
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            if let url = URL(string: "spotify:search:\(encoded)") { _ = await MainActor.run { NSWorkspace.shared.open(url) } }
            Log.info("spotify_play search '\(q)' type=\(type)")
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            var played = false
            let pressReturn = """
                tell application "System Events"
                    tell process "Spotify"
                        set frontmost to true
                        delay 0.3
                        keystroke return
                    end tell
                end tell
                """
            if (try? await AppleScript.run(pressReturn, timeout: 8)) != nil {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let s = try? await Spotify.state(), s.state == "playing" { played = true }
            }
            var j: [String: Any] = ["ok": true, "query": q, "type": type, "search_opened": true, "playing": played]
            if !played { j["note"] = "Spotify is showing search results for '\(q)'. Playback did not start automatically; tell the user the results are up, or ask for a Spotify link to play directly." }
            let s = try? await Spotify.state()
            return .ok(j, cards: [s.map { Spotify.card($0, title: played ? "Playing" : "Searching \"\(q)\"") } ?? Cards.note(source: "Spotify", icon: SpotifyTools.icon, title: "Searching Spotify", body: q)])
        }
    }

    struct Pause: Tool {
        let name = "spotify_pause"
        let description = "Pause Spotify playback. Use for 'pause Spotify', 'stop the music' when Spotify is the player."
        let params: [ToolParam] = []
        let statusLabel = "Pausing"
        let statusIcon = SpotifyTools.icon
        let group = SpotifyTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard Spotify.installed else { return .fail(Spotify.notInstalled) }
            guard Spotify.running else { return .ok(["ok": true, "note": "Spotify is not running; nothing to pause."]) }
            do { _ = try await Spotify.tell("pause"); Log.info("spotify_pause"); return await Spotify.result(title: "Paused") } catch { return Spotify.failure(error) }
        }
    }

    struct Next: Tool {
        let name = "spotify_next"
        let description = "Skip to the next track in Spotify. Use for 'next song', 'skip this' when Spotify is the player."
        let params: [ToolParam] = []
        let statusLabel = "Skipping"
        let statusIcon = SpotifyTools.icon
        let group = SpotifyTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            if let f = await SpotifyTools.precheck() { return f }
            do { _ = try await Spotify.tell("next track"); try? await Task.sleep(nanoseconds: 500_000_000); Log.info("spotify_next"); return await Spotify.result(title: "Now playing") } catch { return Spotify.failure(error) }
        }
    }

    struct Previous: Tool {
        let name = "spotify_previous"
        let description = "Go back to the previous track in Spotify. Use for 'previous song', 'go back a track', 'play that again' when Spotify is the player."
        let params: [ToolParam] = []
        let statusLabel = "Going back"
        let statusIcon = SpotifyTools.icon
        let group = SpotifyTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            if let f = await SpotifyTools.precheck() { return f }
            do { _ = try await Spotify.tell("previous track"); try? await Task.sleep(nanoseconds: 500_000_000); Log.info("spotify_previous"); return await Spotify.result(title: "Now playing") } catch { return Spotify.failure(error) }
        }
    }

    struct NowPlaying: Tool {
        let name = "spotify_now_playing"
        let description = "Get what Spotify is playing right now: track, artist, album, position, play state, volume, shuffle and repeat. Use for 'what song is this', 'what's playing', 'who sings this'."
        let params: [ToolParam] = []
        let statusLabel = "Checking Spotify"
        let statusIcon = SpotifyTools.icon
        let group = SpotifyTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            guard Spotify.installed else { return .fail(Spotify.notInstalled) }
            guard Spotify.running else { return .ok(["ok": true, "running": false, "state": "stopped", "note": "Spotify is not running."]) }
            do {
                let s = try await Spotify.state()
                Log.info("spotify_now_playing \(s.state) \(s.track ?? "-")")
                var j = s.json; j["ok"] = true; j["running"] = true
                return .ok(j, cards: [Spotify.card(s)])
            } catch { return Spotify.failure(error) }
        }
    }

    struct SetVolume: Tool {
        let name = "spotify_set_volume"
        let description = "Set Spotify's volume to an absolute level (0–100) or change it by a relative amount. Use for 'turn Spotify up', 'volume to 40', 'a bit quieter'. Give `level` for absolute, or `delta` for relative (e.g. +10 / -20)."
        let params = [
            ToolParam("level", "integer", "Absolute volume from 0 (silent) to 100 (max)."),
            ToolParam("delta", "integer", "How far to move the volume from wherever it sits now: a positive number raises it, a negative one lowers it. Only consulted if `level` was left out."),
        ]
        let statusLabel = "Volume"
        let statusIcon = SpotifyTools.icon
        let group = SpotifyTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            if let f = await SpotifyTools.precheck() { return f }
            do {
                var target: Int
                if let l = args.int("level") { target = l }
                else if let d = args.int("delta") {
                    let cur = Int(try await Spotify.tell("sound volume")) ?? 50
                    target = cur + d
                } else { return .fail("Give level or delta.") }
                target = min(max(target, 0), 100)
                _ = try await Spotify.tell("set sound volume to \(target)")
                Log.info("spotify_set_volume → \(target)")
                return await Spotify.result(["volume": target], title: "Volume \(target)")
            } catch { return Spotify.failure(error) }
        }
    }

    struct Shuffle: Tool {
        let name = "spotify_shuffle"
        let description = "Turn Spotify shuffle on, off, or toggle it. Use for 'shuffle my playlist', 'turn off shuffle'."
        let params = [ToolParam("mode", "string", "Choose 'on' to switch shuffling on, 'off' to switch it off, or 'toggle' to invert whatever it is set to now; 'toggle' applies when nothing is given.", enumValues: ["on", "off", "toggle"])]
        let statusLabel = "Shuffle"
        let statusIcon = SpotifyTools.icon
        let group = SpotifyTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            if let f = await SpotifyTools.precheck() { return f }
            do {
                let mode = args.str("mode") ?? "toggle"
                let cur = try await Spotify.tell("shuffling") == "true"
                let want = mode == "on" ? true : (mode == "off" ? false : !cur)
                _ = try await Spotify.tell("set shuffling to \(want)")
                Log.info("spotify_shuffle → \(want)")
                return await Spotify.result(["shuffle": want], title: "Shuffle \(want ? "on" : "off")")
            } catch { return Spotify.failure(error) }
        }
    }

    struct Repeat: Tool {
        let name = "spotify_repeat"
        let description = "Turn Spotify repeat on, off, or toggle it. Use for 'repeat this song', 'loop the playlist', 'turn off repeat'."
        let params = [ToolParam("mode", "string", "Choose 'on' to switch repeat on, 'off' to switch it off, or 'toggle' to invert its present setting; with nothing given, 'toggle' applies.", enumValues: ["on", "off", "toggle"])]
        let statusLabel = "Repeat"
        let statusIcon = SpotifyTools.icon
        let group = SpotifyTools.group
        func run(_ args: [String: Any], ctx: ToolContext) async -> ToolResult {
            if let f = await SpotifyTools.precheck() { return f }
            do {
                let mode = args.str("mode") ?? "toggle"
                let cur = try await Spotify.tell("repeating") == "true"
                let want = mode == "on" ? true : (mode == "off" ? false : !cur)
                _ = try await Spotify.tell("set repeating to \(want)")
                Log.info("spotify_repeat → \(want)")
                return await Spotify.result(["repeat": want], title: "Repeat \(want ? "on" : "off")")
            } catch { return Spotify.failure(error) }
        }
    }
}

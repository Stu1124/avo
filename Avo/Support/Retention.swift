import AppKit
import Foundation

/// What Avo keeps on disk, and how to get rid of it.
///
/// Two stores grow without limit otherwise: the screenshots folder (every screen-aware request
/// writes one) and the conversation history. Both have a retention setting and a button; the sweep
/// also runs once shortly after launch, so an install whose owner picked a limit stays bounded
/// without being visited.
///
/// Both settings default to 0 — keep forever — so the sweep deletes nothing until someone chooses
/// a limit. Deleting a user's screenshots or history because they installed an update is not a
/// default anyone asked for.
@MainActor
enum Retention {
    /// Runs both purges with the current settings. A limit of 0 means keep forever, so with the
    /// defaults this does nothing at all. Cheap, and off the launch critical path.
    static func sweep() {
        let s = Settings.shared
        guard s.historyRetentionDays > 0 || s.screenshotRetentionDays > 0 else { return }
        History.shared.purge(olderThan: s.historyRetentionDays)
        _ = purgeScreenshots(olderThan: s.screenshotRetentionDays)
    }

    /// Deletes screenshots last modified more than `days` ago. 0 keeps them forever.
    /// Returns the number of files removed.
    @discardableResult
    static func purgeScreenshots(olderThan days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        for url in screenshotFiles() where !isAttachment(url) {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { Log.info("Screenshots: purged \(removed) file(s) older than \(days) days") }
        return removed
    }

    /// Count and total bytes currently in the screenshots folder, for the settings row.
    static func screenshotUsage() -> (count: Int, bytes: Int64) {
        var bytes: Int64 = 0
        let files = screenshotFiles()
        for url in files {
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files.count, bytes)
    }

    /// Images the user put in the composer themselves (pasted or dropped) share the folder but are
    /// not Avo's captures, so the screenshot retention limit does not apply to them.
    private static func isAttachment(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix("attach-") }

    private static func screenshotFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: Paths.screenshotsDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

/// Zips the log and a settings dump for a bug report. Secrets never leave the Keychain: the dump is
/// built from a fixed list of non-secret keys, so a key added later cannot leak by being forgotten.
///
/// The log is a different matter: it quotes what the user said, and the arguments Avo passed to
/// tools on the strength of it, so `redactSpokenText` (on by default) replaces both before the copy
/// is zipped. `LogRedaction` decides what goes.
@MainActor
enum Diagnostics {
    /// What is cut out of the log copy, and why: `LogRedaction`.
    nonisolated static func redactingSpokenText(_ log: String) -> String { LogRedaction.apply(to: log) }

    /// Writes `~/Desktop/Avo-diagnostics-<date>.zip` and returns it.
    ///
    /// Nothing here belongs on the main actor: it reads and rewrites a log that can be megabytes,
    /// then blocks on `ditto`. Run on the main actor it froze the window for the whole export, so the
    /// button's spinner never drew a frame. Only the settings snapshot needs the main actor, so it is
    /// taken (and serialised, which makes it `Sendable`) before the work moves off.
    nonisolated static func export(redactSpokenText: Bool = true) async throws -> URL {
        let dump = try await MainActor.run {
            try JSONSerialization.data(withJSONObject: settingsDump(), options: [.prettyPrinted, .sortedKeys])
        }
        return try await Task.detached(priority: .userInitiated) {
            try writeArchive(settings: dump, redactSpokenText: redactSpokenText)
        }.value
    }

    nonisolated private static func writeArchive(settings dump: Data, redactSpokenText: Bool) throws -> URL {
        let stamp = ISO8601DateFormatter.diagnosticsDay.string(from: Date())
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Avo-diagnostics-\(stamp)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let log = Paths.appSupport.appendingPathComponent("avo.log")
        let stagedLog = staging.appendingPathComponent("avo.log")
        if FileManager.default.fileExists(atPath: log.path) {
            if redactSpokenText, let text = try? String(contentsOf: log, encoding: .utf8) {
                try? redactingSpokenText(text).write(to: stagedLog, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.copyItem(at: log, to: stagedLog)
            }
        }
        try dump.write(to: staging.appendingPathComponent("settings.json"))

        let destination = Paths.home.appendingPathComponent("Desktop/Avo-diagnostics-\(stamp).zip")
        try? FileManager.default.removeItem(at: destination)
        // `ditto -c -k` is the system's own zip; no third-party archiver, no shell quoting.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // `--norsrc --noextattr` keeps the `__MACOSX` shadow files out; the archive is two plain files.
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", staging.path, destination.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "Avo", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Could not write the zip to the Desktop."])
        }
        Log.info("Diagnostics: wrote \(destination.lastPathComponent)")
        return destination
    }

    /// Every non-secret setting, by name. Keychain-backed values are listed as present/absent only.
    static func settingsDump() -> [String: Any] {
        let s = Settings.shared
        var out: [String: Any] = [
            "app": [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                "system": ProcessInfo.processInfo.operatingSystemVersionString,
            ],
            "model": [
                "apiBaseURL": s.apiBaseURL, "apiStyle": s.apiStyle, "brainModel": s.brainModel,
                "brainEffort": s.brainEffort, "deepEffort": s.deepEffort, "deepMode": s.deepMode,
                "realtimeModel": s.realtimeModel,
            ],
            "voice": [
                "ttsEngine": s.ttsEngine, "ttsModel": s.ttsModel, "ttsVoice": s.ttsVoice,
                "speakReplies": s.speakReplies, "microphoneUID": s.microphoneUID,
                "dictationProfile": s.dictationProfile, "handsFree": s.handsFree, "wakeWord": s.wakeWord,
            ],
            "behaviour": [
                "talkKey": s.talkKey, "composerShortcut": s.composerShortcut,
                "screenAwareness": s.screenAwareness, "alwaysScreenshot": s.alwaysScreenshot,
                "animateScreenshots": s.animateScreenshots, "confirmActions": s.confirmActions,
                "soundsEnabled": s.soundsEnabled, "defaultReminderList": s.defaultReminderList,
                "codingDefaultAgent": s.codingDefaultAgent, "codingAutoApprove": s.codingAutoApprove,
                "screenshotRetentionDays": s.screenshotRetentionDays, "historyRetentionDays": s.historyRetentionDays,
                "onboarded": s.onboarded,
            ],
            "tools": [
                "registered": ToolRegistry.shared.all.count,
                "disabledGroups": UserDefaults.standard.stringArray(forKey: "disabledToolGroups") ?? [],
                "mcpServers": MCPServers.shared.configs.map(\.name),
            ],
            "storage": [
                "contextFileCount": s.contextFiles.count,
                "historyEntries": History.shared.entries.count,
                "screenshotFiles": Retention.screenshotUsage().count,
            ],
        ]
        // Presence, never the value. `writingStyle` and `userName` are the user's own words, so they
        // are described rather than copied.
        out["secrets"] = ["openai", "gemini", "google_client_id", "google_refresh"]
            .reduce(into: [String: Bool]()) { $0[$1] = !(Keychain.get($1) ?? "").isEmpty }
        out["persona"] = ["hasUserName": !s.userName.isEmpty, "writingStyleCharacters": s.writingStyle.count]
        return out
    }
}

extension ISO8601DateFormatter {
    static let diagnosticsDay: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        return f
    }()
}

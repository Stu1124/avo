import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "app.avo.mac", category: "app")
    private static let queue = DispatchQueue(label: "avo.log", qos: .utility)
    private static let fileURL: URL = {
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        return Paths.appSupport.appendingPathComponent("avo.log")
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func info(_ s: String) { logger.info("\(s, privacy: .public)"); write("INFO", s) }
    static func warn(_ s: String) { logger.warning("\(s, privacy: .public)"); write("WARN", s) }
    static func error(_ s: String) { logger.error("\(s, privacy: .public)"); write("ERR ", s) }
    /// For the uncaught-exception handler: the process aborts as soon as the handler returns, so the
    /// line must reach disk on the calling thread, not via the async queue.
    static func errorSync(_ s: String) {
        logger.error("\(s, privacy: .public)")
        append("\(stamp.string(from: Date())) ERR  \(s)\n")
    }

    private static func write(_ level: String, _ s: String) {
        let line = "\(stamp.string(from: Date())) \(level) \(s)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let appSupport = home.appendingPathComponent("Library/Application Support/Avo", isDirectory: true)
    static let memoryFile = appSupport.appendingPathComponent("AVO_MEMORY.md")
    static let googleOAuthFile = appSupport.appendingPathComponent("google-oauth.json")
    static var historyDB: URL { appSupport.appendingPathComponent("history.json") }
    static var remindersDB: URL { appSupport.appendingPathComponent("reminders.json") }
    static var tasksDB: URL { appSupport.appendingPathComponent("coding-tasks.json") }
    static var screenshotsDir: URL { appSupport.appendingPathComponent("screenshots", isDirectory: true) }
}

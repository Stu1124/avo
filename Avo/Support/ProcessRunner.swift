import Foundation

/// Foundation.Process helper: login-shell PATH, resolved CLI binaries, line-by-line stdout, stdin writer.
final class ProcessRunner {
    // MARK: - Shell environment (cached)

    private static let lock = NSLock()
    private static var cachedPATH: String?
    private static var cachedBinaries: [String: String] = [:]
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// PATH from the user's login shell (`/bin/zsh -lc 'echo $PATH'`), computed once.
    static var loginPATH: String {
        lock.lock(); if let p = cachedPATH { lock.unlock(); return p }; lock.unlock()
        var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        if let out = runSync("/bin/zsh", ["-lc", "echo $PATH"], timeout: 10)?
            .split(separator: "\n").last?.trimmingCharacters(in: .whitespacesAndNewlines), out.contains("/") {
            path = out
        }
        let parts = Set(path.split(separator: ":").map(String.init))
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"] where !parts.contains(extra) {
            path += ":" + extra
        }
        lock.lock(); cachedPATH = path; lock.unlock()
        return path
    }

    /// Absolute path of a CLI (`claude`, `codex`) via `command -v` in a login shell, falling back to a PATH scan. Cached.
    static func resolve(_ binary: String) -> String? {
        lock.lock(); if let b = cachedBinaries[binary] { lock.unlock(); return b }; lock.unlock()
        var found: String?
        if let out = runSync("/bin/zsh", ["-lc", "command -v \(binary)"], timeout: 10) {
            // Aliases print "claude: aliased to …"; the binary path is the line starting with "/".
            found = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
        }
        if found == nil {
            for dir in loginPATH.split(separator: ":") {
                let p = "\(dir)/\(binary)"
                if FileManager.default.isExecutableFile(atPath: p) { found = p; break }
            }
        }
        if let f = found { lock.lock(); cachedBinaries[binary] = f; lock.unlock() }
        return found
    }

    /// Environment for child CLIs: login PATH, no nested-Claude marker.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPATH
        env.removeValue(forKey: "CLAUDECODE")          // the CLI refuses to start inside another Claude Code session
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        if env["TERM"] == nil { env["TERM"] = "dumb" }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return env
    }

    /// Run to completion, return stdout (nil on launch failure or timeout).
    @discardableResult
    static func runSync(_ executable: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 30, env: [String: String]? = nil) -> String? {
        _ = ignoreSigpipe
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = env }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Long-lived process with line reader

    let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let queue = DispatchQueue(label: "avo.process.lines", qos: .userInitiated)
    private var buffer = Data()
    private var stdinClosed = false
    private(set) var exitCode: Int32?

    var onLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(executable: String, arguments: [String], cwd: String? = nil, extraEnv: [String: String] = [:]) {
        _ = Self.ignoreSigpipe
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd, FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = Self.environment()
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var isRunning: Bool { process.isRunning }
    var pid: Int32 { process.processIdentifier }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.queue.async { self.consume(d) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            self.queue.async { self.onStderr?(s) }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let code = p.terminationStatus
            // Let the readability handlers deliver the tail, then flush the last partial line.
            self.queue.asyncAfter(deadline: .now() + 0.25) {
                self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe.fileHandleForReading.readabilityHandler = nil
                if !self.buffer.isEmpty {
                    let line = String(decoding: self.buffer, as: UTF8.self)
                    self.buffer.removeAll()
                    if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.onLine?(line) }
                }
                self.exitCode = code
                self.onExit?(code)
            }
        }
        try process.run()
        Log.info("ProcessRunner started pid=\(process.processIdentifier) \(process.executableURL?.lastPathComponent ?? "") \(process.arguments?.prefix(4).joined(separator: " ") ?? "")")
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { onLine?(line) }
        }
    }

    /// Write one line to stdin (newline appended).
    func write(_ line: String) {
        guard !stdinClosed, process.isRunning else { return }
        let data = Data((line + "\n").utf8)
        do { try stdinPipe.fileHandleForWriting.write(contentsOf: data) }
        catch { Log.warn("ProcessRunner stdin write failed: \(error.localizedDescription)") }
    }

    func closeStdin() {
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinPipe.fileHandleForWriting.close()
    }

    func interrupt() { if process.isRunning { process.interrupt() } }
    func terminate() { if process.isRunning { process.terminate() } }
    func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

    /// SIGINT now, SIGTERM after `grace` seconds if still alive, SIGKILL after another `grace`.
    func stop(grace: TimeInterval = 5) {
        interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in self?.kill() }
        }
    }
}

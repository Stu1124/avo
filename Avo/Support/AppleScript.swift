import AppKit
import Foundation

/// Runs AppleScript (via `osascript`, or in-process with NSAppleScript) and small shell helpers with a timeout.
enum AppleScript {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Escape a Swift string as an AppleScript string literal (including the quotes).
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// Run a script with `osascript`. Returns trimmed stdout. Throws with osascript's stderr on failure or timeout.
    static func run(_ source: String, timeout: TimeInterval = 20) async throws -> String {
        let r = try await Shell.run("/usr/bin/osascript", [], stdin: source, timeout: timeout)
        if r.status != 0 {
            let err = r.stderr.isEmpty ? "osascript exited \(r.status)" : r.stderr
            Log.warn("AppleScript failed: \(err.prefix(300))")
            throw Failure(message: cleanError(err))
        }
        return r.stdout
    }

    /// Run in-process with NSAppleScript (main thread). Use only for very short scripts; no hard timeout.
    @MainActor
    static func runInProcess(_ source: String) throws -> String {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw Failure(message: "Could not compile script") }
        let out = script.executeAndReturnError(&err)
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            throw Failure(message: msg)
        }
        return out.stringValue ?? ""
    }

    private static func cleanError(_ s: String) -> String {
        // "123:456: execution error: Messages got an error: Can’t get chat id \"x\". (-1728)"
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "execution error: ") { t = String(t[r.upperBound...]) }
        return t
    }
}

/// Minimal subprocess runner with timeout. Used for osascript, mdfind, textutil.
enum Shell {
    struct Result { var status: Int32; var stdout: String; var stderr: String; var timedOut: Bool }
    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(_ executable: String, _ args: [String], stdin: String? = nil, timeout: TimeInterval = 20) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try runSync(executable, args, stdin: stdin, timeout: timeout)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    static func runSync(_ executable: String, _ args: [String], stdin: String? = nil, timeout: TimeInterval = 20) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let inPipe { p.standardInput = inPipe }
        do { try p.run() } catch { throw Failure(message: "Could not launch \(executable): \(error.localizedDescription)") }
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        var timedOut = false
        let watchdog = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        watchdog.cancel()
        let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut { throw Failure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s") }
        return Result(status: p.terminationStatus, stdout: out, stderr: err, timedOut: false)
    }
}

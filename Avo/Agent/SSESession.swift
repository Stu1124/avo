import Foundation

/// URLSession-backed SSE reader. Per-task state so a cancelled response can never write into the next stream.
final class SSESession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession!
    private struct State {
        var buffer = Data()
        var parser: any SSEEventParser
        let continuation: AsyncStream<BrainEvent>.Continuation
        let label: String
    }
    private let lock = NSLock()
    private var states: [Int: State] = [:]

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func stream(_ request: URLRequest, parser: any SSEEventParser, providerLabel: String) -> AsyncStream<BrainEvent> {
        AsyncStream { cont in
            let task = self.session.dataTask(with: request)
            let id = task.taskIdentifier
            self.lock.lock(); self.states[id] = State(parser: parser, continuation: cont, label: providerLabel); self.lock.unlock()
            cont.onTermination = { [weak self, weak task] _ in
                task?.cancel()
                guard let self else { return }
                self.lock.lock(); self.states.removeValue(forKey: id); self.lock.unlock()
            }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var cont: AsyncStream<BrainEvent>.Continuation?
        var events: [BrainEvent] = []
        lock.lock()
        if var s = states[dataTask.taskIdentifier] {
            s.buffer.append(data)
            while let r = s.buffer.range(of: Data("\n\n".utf8)) {
                let block = s.buffer.subdata(in: 0..<r.lowerBound)
                s.buffer.removeSubrange(0..<r.upperBound)
                events.append(contentsOf: s.parser.feed(block))
            }
            cont = s.continuation
            states[dataTask.taskIdentifier] = s
        }
        lock.unlock()
        for e in events { cont?.yield(e) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let removed = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard var s = removed else { return }
        if let e = error as NSError?, e.code != NSURLErrorCancelled {
            s.continuation.yield(.error(e.localizedDescription))
        } else if let http = task.response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(decoding: s.buffer, as: UTF8.self)
            s.continuation.yield(.error("\(s.label) \(http.statusCode): \(body.prefix(300))"))
        } else {
            if !s.buffer.isEmpty { for e in s.parser.feed(s.buffer) { s.continuation.yield(e) } }
            for e in s.parser.finish() { s.continuation.yield(e) }
        }
        s.continuation.finish()
    }
}

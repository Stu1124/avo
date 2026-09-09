import AppKit
import CryptoKit
import Foundation
import Network

/// Desktop-app OAuth 2.0 (PKCE + loopback redirect) for Google. Refresh token and account email live in the Keychain via `Settings`.
@MainActor
final class GoogleAuth {
    static let shared = GoogleAuth()

    static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/drive",
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/userinfo.email",
        "openid",
    ]
    nonisolated static let notConnectedMessage = "Google is not connected."
    nonisolated static let notConnectedGuidance = "Google is not connected. Open Avo Settings → Google → Connect."

    struct AuthError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private var cachedToken: String?
    private var cachedExpiry: Date = .distantPast
    private var refreshTask: Task<String, Error>?
    private var activeListener: NWListener?

    private init() {}

    // MARK: State

    var isConnected: Bool { Settings.shared.googleRefreshToken != nil }
    var email: String? { Settings.shared.googleAccountEmail }

    func signOut() {
        activeListener?.cancel(); activeListener = nil
        refreshTask?.cancel(); refreshTask = nil
        cachedToken = nil
        cachedExpiry = .distantPast
        Settings.shared.googleRefreshToken = nil
        Keychain.delete("google_email")
        Log.info("Google signed out")
    }

    // MARK: Sign in

    /// Opens the consent page in the default browser, waits for the loopback callback, exchanges the code and stores the refresh token. Returns the account email.
    func signIn() async throws -> String {
        guard let clientId = Settings.shared.googleClientId, !clientId.isEmpty,
              let clientSecret = Settings.shared.googleClientSecret, !clientSecret.isEmpty else {
            throw AuthError(message: "No Google OAuth client configured. Put google-oauth.json (a Desktop-app client) in the Avo project folder and relaunch.")
        }
        activeListener?.cancel(); activeListener = nil

        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Self.randomURLSafe(bytes: 16)

        let listener = try LoopbackListener()
        activeListener = listener.listener
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)/callback"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "include_granted_scopes", value: "true"),
        ]
        guard let url = comps.url else { throw AuthError(message: "Could not build the Google consent URL.") }
        Log.info("Google sign-in: listening on port \(port), opening consent page")
        NSWorkspace.shared.open(url)

        let code: String
        do {
            code = try await listener.waitForCode(expectedState: state, timeout: 300)
        } catch {
            activeListener = nil
            throw error
        }
        activeListener = nil

        let form: [String: String] = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let token = try await Self.tokenRequest(form)
        guard let access = token["access_token"] as? String else { throw AuthError(message: "Google did not return an access token.") }
        guard let refresh = token["refresh_token"] as? String else {
            throw AuthError(message: "Google did not return a refresh token. Remove Avo from your Google account's third-party access page and try again.")
        }
        let expires = (token["expires_in"] as? Double) ?? 3600
        cachedToken = access
        cachedExpiry = Date().addingTimeInterval(expires - 60)
        Settings.shared.googleRefreshToken = refresh

        let email = try await Self.fetchEmail(accessToken: access)
        Settings.shared.googleAccountEmail = email
        Log.info("Google connected as \(email)")
        return email
    }

    // MARK: Access token

    /// Returns a valid access token, refreshing it when expired. Cached in memory.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = cachedToken, Date() < cachedExpiry { return t }
        if let running = refreshTask { return try await running.value }
        guard let refresh = Settings.shared.googleRefreshToken else { throw AuthError(message: Self.notConnectedGuidance) }
        guard let clientId = Settings.shared.googleClientId, let clientSecret = Settings.shared.googleClientSecret else {
            throw AuthError(message: "No Google OAuth client configured. Add google-oauth.json and relaunch Avo.")
        }
        let task = Task<String, Error> {
            let form: [String: String] = [
                "refresh_token": refresh,
                "client_id": clientId,
                "client_secret": clientSecret,
                "grant_type": "refresh_token",
            ]
            do {
                let token = try await Self.tokenRequest(form)
                guard let access = token["access_token"] as? String else { throw AuthError(message: "Google did not return an access token.") }
                let expires = (token["expires_in"] as? Double) ?? 3600
                self.cachedToken = access
                self.cachedExpiry = Date().addingTimeInterval(expires - 60)
                return access
            } catch let e as AuthError where e.message.contains("invalid_grant") {
                self.signOut()
                throw AuthError(message: "Google session expired or was revoked. Open Avo Settings → Google → Connect to reconnect.")
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: Helpers for tools

    /// Glance card telling the user how to connect. Shown by tools when signed out.
    func connectCard() -> CardKind {
        .glance(GlanceCard(id: UUID(), blocks: [
            .header(title: "Connect Google", subtitle: "Gmail, Calendar and Drive", icon: "person.crop.circle.badge.plus"),
            .text("Open Avo Settings → Google → Connect and sign in with your Google account."),
        ], source: "Google", sourceIcon: "globe"))
    }

    /// Returns a failure result (with the connect card) when signed out, otherwise nil.
    func requireToken() -> ToolResult? {
        if isConnected { return nil }
        return ToolResult(json: ["ok": false, "error": Self.notConnectedMessage, "guidance": Self.notConnectedGuidance],
                          cards: [connectCard()], ok: false)
    }

    // MARK: Token endpoint

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(formEncode(form).utf8)
        req.timeoutInterval = 30
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AuthError(message: "Could not reach Google: \(error.localizedDescription)") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let code = obj["error"] as? String ?? "http \(status)"
            let desc = obj["error_description"] as? String ?? ""
            throw AuthError(message: "Google token error: \(code)\(desc.isEmpty ? "" : " — \(desc)")")
        }
        return obj
    }

    private static func fetchEmail(accessToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let email = obj["email"] as? String else { throw AuthError(message: "Could not read the account email from Google.") }
        return email
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

// MARK: - Loopback HTTP listener (Network.framework)

/// Minimal one-shot HTTP server on 127.0.0.1 that captures the OAuth redirect and serves a small confirmation page.
private final class LoopbackListener: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "avo.google.loopback")
    private var continuation: CheckedContinuation<String, Error>?
    private var expectedState = ""
    private var finished = false
    private let lock = NSLock()

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    /// Starts listening and returns the chosen port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            let resumed = ResumeFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    let port = self.listener.port?.rawValue ?? 0
                    if port == 0 { cont.resume(throwing: GoogleAuth.AuthError(message: "Loopback listener did not get a port.")) }
                    else { cont.resume(returning: port) }
                case .failed(let e):
                    if resumed.claim() { cont.resume(throwing: GoogleAuth.AuthError(message: "Loopback listener failed: \(e.localizedDescription)")) }
                    else { self.finish(.failure(GoogleAuth.AuthError(message: "Loopback listener failed: \(e.localizedDescription)"))) }
                case .cancelled:
                    if resumed.claim() { cont.resume(throwing: GoogleAuth.AuthError(message: "Sign-in was cancelled.")) }
                    else { self.finish(.failure(GoogleAuth.AuthError(message: "Sign-in was cancelled."))) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func waitForCode(expectedState: String, timeout: TimeInterval) async throws -> String {
        self.expectedState = expectedState
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finish(.failure(GoogleAuth.AuthError(message: "Timed out waiting for Google sign-in (5 minutes). Try again.")))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true; continuation = nil
        lock.unlock()
        listener.cancel()
        cont.resume(with: result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
                guard let self else { conn.cancel(); return }
                if let data { buffer.append(data) }
                if buffer.count > 65536 || error != nil { conn.cancel(); return }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    self.respond(conn, requestHead: head)
                } else if isComplete { conn.cancel() }
                else { readMore() }
            }
        }
        readMore()
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let requestLine = requestHead.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        let comps = URLComponents(string: "http://127.0.0.1\(target)")
        let items = comps?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }

        var outcome: Result<String, Error>? = nil
        var html: String
        if comps?.path == "/callback" {
            if let err = q("error") {
                let msg = err == "access_denied" ? "You declined the Google permission request." : "Google returned an error: \(err)"
                outcome = .failure(GoogleAuth.AuthError(message: msg))
                html = Self.page(title: "Avo could not connect", body: msg)
            } else if let code = q("code"), q("state") == expectedState {
                outcome = .success(code)
                html = Self.page(title: "Avo is connected.", body: "You can close this tab.")
            } else {
                outcome = .failure(GoogleAuth.AuthError(message: "The sign-in response did not match this session. Try again."))
                html = Self.page(title: "Avo could not connect", body: "The response did not match this sign-in attempt. Go back to Avo and try again.")
            }
        } else {
            html = Self.page(title: "Avo", body: "Waiting for Google sign-in…")
        }
        let body = Data(html.utf8)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        conn.send(content: Data(response.utf8) + body, completion: .contentProcessed { [weak self] _ in
            conn.cancel()
            if let outcome { self?.finish(outcome) }
        })
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Avo</title>
        <style>
        html,body{height:100%;margin:0}
        body{display:flex;align-items:center;justify-content:center;background:#0b0b0e;color:#f2f2f5;
        font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;
        background-image:radial-gradient(60% 50% at 50% 0%,rgba(120,120,255,.18),transparent 70%)}
        .card{padding:36px 40px;border-radius:24px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);
        box-shadow:0 30px 80px rgba(0,0,0,.6),inset 0 1px 0 rgba(255,255,255,.08);backdrop-filter:blur(30px) saturate(180%);-webkit-backdrop-filter:blur(30px) saturate(180%);
        text-align:center;max-width:420px}
        .dot{width:44px;height:44px;border-radius:50%;margin:0 auto 18px;background:radial-gradient(circle at 35% 35%,#fff,#9aa4ff 55%,#3a3f8f);box-shadow:0 0 30px rgba(140,150,255,.5)}
        h1{font-size:20px;font-weight:600;margin:0 0 8px;letter-spacing:-.01em}
        p{margin:0;font-size:14px;color:rgba(242,242,245,.65);line-height:1.45}
        </style></head><body><div class="card"><div class="dot"></div><h1>\(escape(title))</h1><p>\(escape(body))</p></div></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// One-shot flag safe to touch from a Network.framework queue.
private final class ResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true exactly once.
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

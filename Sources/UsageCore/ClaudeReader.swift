import Foundation

/// Reads Claude subscription usage from the authenticated OAuth usage endpoint.
/// The 5h/weekly utilization Claude shows in `/usage` is not written to local
/// files, so we call `GET /api/oauth/usage` with the Bearer token Claude Code
/// keeps refreshed in `~/.claude/.credentials.json` — the CLI's own login, a
/// `0600` file. The endpoint rate limits aggressively without a
/// `claude-code/<version>` User-Agent, so poll no more than ~once per 3 minutes.
///
/// Where the token lives depends on the machine: Claude Code writes it to the
/// login **keychain** by default on macOS, but on installs that also keep
/// `~/.claude/.credentials.json` the file is what stays current (measured: on a
/// machine with both, the keychain copy went a month stale while the file was
/// refreshed hourly). So we read the **file first**, then fall back to the
/// keychain via `/usr/bin/security`.
///
/// We shell out to `security` rather than call `SecItemCopyMatching` in-process
/// on purpose. macOS attributes the one-time "Always Allow" to the *requesting*
/// binary. `security` has a stable Apple signature, so that grant persists
/// forever; our ad-hoc app signature changes every build, so an in-process read
/// would re-prompt after every update. This is how other menu-bar apps
/// "auto-connect" to Claude Code.
public enum ClaudeReader {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static let keychainService = "Claude Code-credentials"

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// Read the token from whichever store is **freshest** (latest `expiresAt`).
    ///
    /// Claude Code on macOS keeps the **keychain** current (it refreshes there when you run
    /// `claude`), so the app must read the keychain — not a stale file copy.
    ///
    /// An earlier version materialised a file from the keychain and then only
    /// ever read that file; running `claude` refreshed the keychain but the app
    /// kept showing the frozen file, so it looked permanently expired. Picking
    /// the fresher of the two fixes that: the moment `claude` refreshes the
    /// keychain, the app sees it. We consult the keychain only when the file
    /// isn't clearly fresh, to avoid spawning `security` on every healthy poll.
    static func loadCredentials() -> (data: Data, source: String)? {
        let fileData = (try? Data(contentsOf: credentialsURL))
            .flatMap { parseToken(from: $0) != nil ? $0 : nil }
        let fileExpiry = fileData.flatMap { expiresAt(from: $0) } ?? .distantPast

        var keychainData: Data?
        if fileData == nil || fileExpiry.timeIntervalSinceNow < 1800 {
            if let raw = runCommand("/usr/bin/security",
                                    ["find-generic-password", "-s", keychainService, "-w"]),
               let data = raw.data(using: .utf8), parseToken(from: data) != nil {
                keychainData = data
            }
        }
        let keychainExpiry = keychainData.flatMap { expiresAt(from: $0) } ?? .distantPast

        // Freshest wins; ties go to the file (no keychain prompt, self-refreshable).
        if let fileData, fileExpiry >= keychainExpiry { return (fileData, "file") }
        if let keychainData { return (keychainData, "keychain") }
        if let fileData { return (fileData, "file") }
        return nil
    }

    /// Multi-line summary for `usage-probe`. Shows both stores' freshness so a
    /// "still expired after running claude" case is self-explaining. No secrets.
    public static func diagnosticCredentialSource() -> String {
        func expiryText(_ data: Data?) -> String {
            guard let data, parseToken(from: data) != nil else { return "없음/해석불가" }
            guard let expiry = expiresAt(from: data) else { return "만료시각 미상" }
            let h = expiry.timeIntervalSinceNow / 3600
            return h > 0 ? String(format: "만료 %.1fh 후", h) : String(format: "%.1fh 전 만료", -h)
        }
        let fileData = try? Data(contentsOf: credentialsURL)
        let keychainData = runCommand("/usr/bin/security",
            ["find-generic-password", "-s", keychainService, "-w"])?.data(using: .utf8)

        guard let (chosen, source) = loadCredentials() else {
            return "파일·키체인 어디에도 없음 — 해당 PC에서 `claude` 로그인 필요"
        }
        let usedExpiry = expiryText(chosen)
        return "사용: \(source) (\(usedExpiry)) | 파일: \(expiryText(fileData)) | 키체인: \(expiryText(keychainData))"
    }

    /// The token is read fresh on every call so we always use the value Claude
    /// Code most recently refreshed, and it never lives anywhere but memory.
    static func accessToken() -> String? {
        guard let (data, _) = loadCredentials() else { return nil }
        return parseToken(from: data)
    }

    // MARK: - Refresh via the Claude Code CLI

    /// Throttle so a run of failures can't spawn `claude` repeatedly. Only ever
    /// touched from the serialized Claude fetch, so unsynchronized access is safe.
    nonisolated(unsafe) static var lastCLIRefresh: Date?

    /// For `usage-probe`: whether the CLI-refresh path can find `claude`.
    public static func diagnosticClaudeBinary() -> String {
        locateClaudeBinary() ?? "claude 실행파일 못 찾음 (터미널 없이 갱신 불가)"
    }

    /// Find the `claude` executable. GUI apps launch with a minimal PATH, so we
    /// check the usual install locations first, then fall back to the user's
    /// login shell to resolve whatever `claude` they actually use.
    static func locateClaudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let found = runCommand(shell, ["-lc", "command -v claude"]),
           FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    /// Ask Claude Code to refresh its own token by making one tiny print-mode
    /// call. This is the keychain-safe way to stay logged in without a terminal:
    /// Claude Code rotates and rewrites its own credential (keychain on macOS),
    /// and we just read the fresh value afterwards — we never write the keychain.
    ///
    /// Costs one trivial message, so it's throttled and only used as a last
    /// resort when the token has actually expired. Returns true if `claude` ran.
    @discardableResult
    static func triggerCLIRefresh(now: Date = Date(), timeout: TimeInterval = 45) -> Bool {
        if let last = lastCLIRefresh, now.timeIntervalSince(last) < 1800 { return false }
        guard let claude = locateClaudeBinary() else { return false }
        lastCLIRefresh = now
        _ = runCommand(claude, ["-p", "ok"], timeout: timeout)
        return true
    }

    /// `expiresAt` is epoch **milliseconds**; used only to explain a 401.
    static func expiresAt(from data: Data) -> Date? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        let ms = doubleVal(oauth["expiresAt"])
        return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
    }

    // MARK: - Token refresh

    /// Public OAuth client id Claude Code uses (extracted from the CLI). The
    /// refresh grant needs it alongside the refresh token.
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// `platform.claude.com` is Cloudflare-gated against non-browser callers;
    /// `api.anthropic.com` serves the same token grant and accepts our request.
    static let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!

    /// Refresh the access token in `~/.claude/.credentials.json` when it is near
    /// expiry, so the app keeps working without the user running `claude`.
    ///
    /// We do this **only when credentials live in the file** — never when they
    /// came from the keychain. The refresh token rotates: refreshing invalidates
    /// the previous one, so if we refreshed the keychain's token out from under
    /// Claude Code, its own next run could be forced to re-login. Owning the file
    /// copy keeps our rotation isolated from Claude Code's keychain copy.
    ///
    /// Returns the fresh access token when a refresh happened, else nil.
    @discardableResult
    static func refreshIfNeeded(force: Bool = false, timeout: TimeInterval = 15) -> String? {
        // Only the file is safe to rotate (see above).
        guard let data = try? Data(contentsOf: credentialsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty
        else { return nil }

        // Refresh only within 10 min of expiry (or when forced by a 401), so we
        // don't rotate needlessly and race Claude Code's own refresh-on-run.
        if !force, let expiry = expiresAt(from: data),
           expiry.timeIntervalSinceNow > 600 { return nil }

        let response = HTTP.postForm(tokenURL, fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
        ], headers: ["Accept": "application/json"], timeout: timeout)

        guard response.status == 200, let body = response.data,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let newAccess = json["access_token"] as? String, !newAccess.isEmpty
        else { return nil }

        guard let merged = mergedCredentials(original: obj, oldOAuth: oauth,
                                             response: json, now: Date()) else { return nil }
        writeBack(merged)
        return newAccess
    }

    /// Pure: fold the token response into the existing credentials JSON,
    /// preserving every other field (both top-level and inside `claudeAiOauth`),
    /// and return the bytes to persist. Returns nil if the response lacks a token.
    /// Split out from the file write so it can be unit-tested.
    static func mergedCredentials(original: [String: Any],
                                  oldOAuth: [String: Any],
                                  response: [String: Any],
                                  now: Date) -> Data? {
        guard let newAccess = response["access_token"] as? String, !newAccess.isEmpty else {
            return nil
        }
        var oauth = oldOAuth
        oauth["accessToken"] = newAccess
        if let newRefresh = response["refresh_token"] as? String, !newRefresh.isEmpty {
            oauth["refreshToken"] = newRefresh
        }
        if let expiresIn = response["expires_in"] as? Double {
            oauth["expiresAt"] = Int(now.timeIntervalSince1970 * 1000 + expiresIn * 1000)
        }
        var merged = original
        merged["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: merged)
    }

    /// Atomically rewrite the credentials file, preserving `0600` permissions. A
    /// partial write here would lock the user out, so we write a temp file and
    /// rename over the original.
    static func writeBack(_ data: Data) {
        let tmp = credentialsURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(credentialsURL, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// `{"claudeAiOauth": {"accessToken": …}}`, tolerating a flat shape or a
    /// bare token string.
    static func parseToken(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let oauth = obj["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String, !token.isEmpty {
                return token
            }
            if let token = obj["accessToken"] as? String, !token.isEmpty { return token }
            return nil
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Best-effort Claude Code version for the User-Agent, pulled from the most
    /// recent transcript. Falls back to a recent version if none is found.
    static func claudeCodeVersion() -> String {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: projects,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return "2.1.0" }
        var newest: (URL, Date)?
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || mod > newest!.1 { newest = (url, mod) }
        }
        guard let file = newest?.0,
              let content = try? String(contentsOf: file, encoding: .utf8) else { return "2.1.0" }
        for line in content.split(separator: "\n").reversed() {
            guard line.contains("\"version\"") else { continue }
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let v = obj["version"] as? String { return v }
        }
        return "2.1.0"
    }

    static func makeISO() -> [ISO8601DateFormatter] {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFrac, plain]
    }

    static func parseDate(_ s: String?, _ formatters: [ISO8601DateFormatter]) -> Date? {
        guard let s else { return nil }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    static func failure(_ message: String) -> ProviderUsage {
        ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil,
                      sampledAt: Date(), error: message)
    }

    /// Synchronous fetch (blocks the calling thread). Call off the main thread.
    ///
    /// `cliRefresh`: when the token has expired and can't be refreshed from the
    /// file, run `claude -p` to let Claude Code refresh its own (keychain) login.
    /// Off by default; the app passes the user's setting.
    public static func fetch(timeout: TimeInterval = 15, cliRefresh: Bool = false) -> ProviderUsage {
        // No readable credentials at all — a CLI refresh might create them.
        var loaded = loadCredentials()
        if loaded == nil, cliRefresh, triggerCLIRefresh() {
            loaded = loadCredentials()
        }
        guard var (data, source) = loaded else {
            return failure("Claude 인증 정보를 찾지 못함 — 해당 PC에서 `claude` 로그인 필요")
        }

        // Self-refresh only the *file* token, and only when the file is the store
        // we're actually using. We must never rotate the keychain's token: that
        // would invalidate Claude Code's own refresh token and force it to
        // re-login. When the keychain is the fresh source (because the user runs
        // `claude`), we just read it.
        if source == "file" {
            refreshIfNeeded(timeout: timeout)
            if let reloaded = loadCredentials() { (data, source) = reloaded }
        }

        guard let token = parseToken(from: data) else {
            return failure("인증 정보를 해석하지 못함 — claude 재로그인 필요")
        }

        let usage = requestUsage(token: token, timeout: timeout)

        // A 401/403 despite a "valid-looking" token: recover in order —
        // 1) file self-refresh, 2) let Claude Code refresh its own login via the
        // CLI (keychain-safe), then retry once.
        if case let .authFailed(status) = usage {
            if source == "file", let refreshed = refreshIfNeeded(force: true, timeout: timeout) {
                let retry = requestUsage(token: refreshed, timeout: timeout)
                return retry.toProviderUsage(dataForExpiry: try? Data(contentsOf: credentialsURL),
                                             lastStatus: status)
            }
            if cliRefresh, triggerCLIRefresh(),
               let (freshData, _) = loadCredentials(), let freshToken = parseToken(from: freshData) {
                let retry = requestUsage(token: freshToken, timeout: timeout)
                return retry.toProviderUsage(dataForExpiry: freshData, lastStatus: status)
            }
            return failure(cliRefresh
                ? "토큰 갱신 실패 — 해당 PC에서 `claude` 재로그인이 필요할 수 있습니다"
                : "토큰 만료 — 해당 PC에서 `claude`를 한 번 실행하면 갱신됩니다")
        }
        return usage.toProviderUsage(dataForExpiry: data, lastStatus: nil)
    }

    private enum UsageResult {
        case ok([String: Any])
        case authFailed(Int)
        case rateLimited
        case transport(String)
        case http(Int)

        func toProviderUsage(dataForExpiry: Data?, lastStatus: Int?) -> ProviderUsage {
            switch self {
            case let .ok(obj): return parse(obj)
            case let .authFailed(status):
                if let d = dataForExpiry, let expiry = expiresAt(from: d), expiry < Date() {
                    return failure("토큰 만료 — 자동 갱신 실패. 해당 PC에서 `claude` 재로그인 필요")
                }
                return failure("인증 거부됨 (HTTP \(status)) — claude 재로그인 필요")
            case .rateLimited: return failure("rate limited (429) — polling too fast")
            case let .transport(msg): return failure(msg)
            case let .http(status): return failure("HTTP \(status)")
            }
        }
    }

    private static func requestUsage(token: String, timeout: TimeInterval) -> UsageResult {
        let response = HTTP.get(usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "User-Agent": "claude-code/\(claudeCodeVersion())",
            "Content-Type": "application/json",
        ], timeout: timeout)

        if let transport = response.transportError { return .transport(transport) }
        switch response.status {
        case 200:
            guard let data = response.data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .http(200) }
            return .ok(obj)
        case 401, 403: return .authFailed(response.status)
        case 429: return .rateLimited
        default: return .http(response.status)
        }
    }

    static func parse(_ obj: [String: Any]) -> ProviderUsage {
        let formatters = makeISO()
        func window(_ key: String, _ w: UsageWindow) -> RateWindow? {
            guard let d = obj[key] as? [String: Any],
                  let reset = parseDate(d["resets_at"] as? String, formatters) else { return nil }
            return RateWindow(window: w, usedPercent: doubleVal(d["utilization"]), resetsAt: reset)
        }
        return ProviderUsage(
            provider: .claude,
            fiveHour: window("five_hour", .fiveHour),
            weekly: window("seven_day", .weekly),
            sampledAt: Date()
        )
    }
}

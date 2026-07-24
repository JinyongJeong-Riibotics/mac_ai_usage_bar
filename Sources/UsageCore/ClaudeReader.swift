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

    /// File → keychain, tagged with which one answered (for diagnostics).
    static func loadCredentials() -> (data: Data, source: String)? {
        if let data = try? Data(contentsOf: credentialsURL) {
            return (data, "file")
        }
        if let raw = runCommand("/usr/bin/security",
                                ["find-generic-password", "-s", keychainService, "-w"]),
           let data = raw.data(using: .utf8) {
            return (data, "keychain")
        }
        return nil
    }

    /// One-line summary for `usage-probe`. Reveals no token material.
    public static func diagnosticCredentialSource() -> String {
        guard let (data, source) = loadCredentials() else {
            return "파일·키체인 어디에도 없음 — 해당 PC에서 `claude` 로그인 필요"
        }
        guard parseToken(from: data) != nil else {
            return "\(source)에서 읽었으나 토큰을 해석하지 못함 — claude 재로그인 필요"
        }
        let where_ = source == "file" ? "~/.claude/.credentials.json" : "키체인(/usr/bin/security)"
        var line = "\(where_) 에서 읽음"
        if let expiry = expiresAt(from: data) {
            let hours = expiry.timeIntervalSinceNow / 3600
            line += hours > 0
                ? String(format: " (토큰 만료 %.1f시간 후)", hours)
                : String(format: " (토큰 %.1f시간 전 만료 — claude 실행해 갱신 필요)", -hours)
        }
        return line
    }

    /// The token is read fresh on every call so we always use the value Claude
    /// Code most recently refreshed, and it never lives anywhere but memory.
    static func accessToken() -> String? {
        guard let (data, _) = loadCredentials() else { return nil }
        return parseToken(from: data)
    }

    /// `expiresAt` is epoch **milliseconds**; used only to explain a 401.
    static func expiresAt(from data: Data) -> Date? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        let ms = doubleVal(oauth["expiresAt"])
        return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
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
    public static func fetch(timeout: TimeInterval = 15) -> ProviderUsage {
        guard let (data, _) = loadCredentials() else {
            return failure("Claude 인증 정보를 찾지 못함 — 해당 PC에서 `claude` 로그인 필요")
        }
        guard let token = parseToken(from: data) else {
            return failure("인증 정보를 해석하지 못함 — claude 재로그인 필요")
        }

        let response = HTTP.get(usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "User-Agent": "claude-code/\(claudeCodeVersion())",
            "Content-Type": "application/json",
        ], timeout: timeout)

        if let transport = response.transportError { return failure(transport) }

        switch response.status {
        case 200:
            guard let data = response.data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return failure("응답을 해석하지 못함") }
            return parse(obj)
        case 401, 403:
            // Almost always an expired token the CLI has not refreshed yet.
            if let expiry = expiresAt(from: data), expiry < Date() {
                return failure("토큰 만료됨 — claude를 한 번 실행해 갱신하세요")
            }
            return failure("인증 거부됨 (HTTP \(response.status)) — claude 재로그인 필요")
        case 429:
            return failure("rate limited (429) — polling too fast")
        default:
            return failure("HTTP \(response.status)")
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

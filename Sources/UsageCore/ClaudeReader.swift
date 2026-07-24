import Foundation

/// Reads Claude subscription usage from the authenticated OAuth usage endpoint.
/// The 5h/weekly utilization Claude shows in `/usage` is not written to local
/// files, so we call `GET /api/oauth/usage` with the Bearer token Claude Code
/// keeps refreshed in `~/.claude/.credentials.json` — the CLI's own login, a
/// `0600` file. The endpoint rate limits aggressively without a
/// `claude-code/<version>` User-Agent, so poll no more than ~once per 3 minutes.
///
/// We deliberately do **not** read the login keychain. Claude Code stores tokens
/// there by default on macOS, but another app reading that item makes macOS ask
/// for the keychain password on every access, and measurements on a machine that
/// had both showed the keychain copy going a month stale while the file stayed
/// current. `setupCommand` tells the user how to materialise the file instead.
public enum ClaudeReader {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// One-time command that copies Claude Code's keychain login into the file
    /// this reader uses. Shown in the UI when the file is absent.
    public static let setupCommand =
        #"security find-generic-password -s "Claude Code-credentials" -w > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json"#

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// One-line summary for `usage-probe`. Reveals no token material.
    public static func diagnosticCredentialSource() -> String {
        guard let data = try? Data(contentsOf: credentialsURL) else {
            return "~/.claude/.credentials.json 없음 (아래 명령으로 생성)\n    \(setupCommand)"
        }
        guard parseToken(from: data) != nil else {
            return "파일은 있으나 토큰을 해석하지 못함 — claude 재로그인 필요"
        }
        var line = "~/.claude/.credentials.json 에서 읽음"
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
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
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
        guard let data = try? Data(contentsOf: credentialsURL) else {
            return failure("~/.claude/.credentials.json 없음 — 터미널에서 한 번 실행:\n\(setupCommand)")
        }
        guard let token = parseToken(from: data) else {
            return failure("인증 파일을 해석하지 못함 — claude 재로그인 필요")
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

import Foundation

/// Reads Codex usage live from the same endpoint the Codex CLI polls, using the
/// CLI's own `~/.codex/auth.json` (a `0600` plaintext file — the terminal login,
/// no keychain involved). The local rollout logs are kept only as a fallback:
/// they reflect the last time *this machine* ran Codex, so on a machine that has
/// not run Codex in days they report a stale percentage.
public enum CodexReader {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    struct Auth {
        let accessToken: String
        let accountID: String
    }

    static func loadAuth() -> Auth? {
        guard let obj = readJSONFile(authURL),
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        let account = tokens["account_id"] as? String ?? ""
        return Auth(accessToken: token, accountID: account)
    }

    /// Live usage. Falls back to the local logs when the endpoint can't be
    /// reached or the CLI's token has expired, so the menu keeps showing
    /// *something* — flagged as stale by its `sampledAt`.
    public static func fetch(timeout: TimeInterval = 15) -> ProviderUsage {
        guard let auth = loadAuth() else {
            return fallback(reason: "~/.codex/auth.json 없음 — 해당 PC에서 codex 로그인 필요")
        }

        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "Accept": "application/json",
            "User-Agent": "codex-cli",
        ]
        if !auth.accountID.isEmpty { headers["chatgpt-account-id"] = auth.accountID }

        let response = HTTP.get(usageURL, headers: headers, timeout: timeout)
        if let transport = response.transportError {
            return fallback(reason: "조회 실패: \(transport)")
        }
        switch response.status {
        case 200:
            guard let data = response.data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = parseUsage(obj)
            else { return fallback(reason: "응답을 해석하지 못함") }
            return usage
        case 401, 403:
            // The CLI refreshes this token roughly every 10 days; running codex
            // once on that machine restores it.
            return fallback(reason: "codex 인증 만료 — 해당 PC에서 codex를 한 번 실행")
        case 429:
            return fallback(reason: "요청이 너무 잦음 (429) — 갱신 주기를 늘리세요")
        default:
            return fallback(reason: "HTTP \(response.status)")
        }
    }

    /// `{"rate_limit": {"primary_window": {...}, "secondary_window": {...}}}`,
    /// where each window carries `used_percent`, `limit_window_seconds`
    /// (18000 = 5h, 604800 = weekly) and an epoch `reset_at`.
    static func parseUsage(_ obj: [String: Any], now: Date = Date()) -> ProviderUsage? {
        guard let limits = obj["rate_limit"] as? [String: Any] else { return nil }
        var five: RateWindow?
        var week: RateWindow?
        for key in ["primary_window", "secondary_window"] {
            guard let w = limits[key] as? [String: Any] else { continue }
            guard let win = parseWindow(w, now: now) else { continue }
            if win.window == .fiveHour { five = win } else { week = win }
        }
        guard five != nil || week != nil else { return nil }
        return ProviderUsage(provider: .codex, fiveHour: five, weekly: week, sampledAt: now)
    }

    static func parseWindow(_ w: [String: Any], now: Date) -> RateWindow? {
        let seconds = intVal(w["limit_window_seconds"])
        guard seconds > 0 else { return nil }
        // Anything shorter than a day is the rolling 5h window; the other is weekly.
        let window: UsageWindow = seconds <= 86400 ? .fiveHour : .weekly
        let reset: Date
        if let at = w["reset_at"], intVal(at) > 0 {
            reset = Date(timeIntervalSince1970: doubleVal(at))
        } else {
            reset = now.addingTimeInterval(doubleVal(w["reset_after_seconds"]))
        }
        return RateWindow(window: window, usedPercent: doubleVal(w["used_percent"]), resetsAt: reset)
    }

    /// Local-log reading, annotated with why the live call didn't happen.
    static func fallback(reason: String) -> ProviderUsage {
        let local = latest()
        let note = "\(reason) · 이 PC의 로컬 로그 사용"
        return ProviderUsage(provider: .codex,
                             fiveHour: local.fiveHour,
                             weekly: local.weekly,
                             sampledAt: local.sampledAt,
                             error: local.fiveHour == nil && local.weekly == nil
                                 ? "\(reason) · 로컬 로그에도 기록 없음"
                                 : note)
    }

    static func rolloutFilesNewestFirst(limit: Int) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, mod))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.1) }
    }

    /// Number of rollout logs the scan can see, for `usage-probe` diagnostics.
    public static func diagnosticSessionCount(scanLimit: Int = 40) -> Int {
        rolloutFilesNewestFirst(limit: scanLimit).count
    }

    /// One-line auth summary for `usage-probe`. Reveals no token material.
    public static func diagnosticAuthSource() -> String {
        guard let auth = loadAuth() else {
            return "~/.codex/auth.json 없음 — 해당 PC에서 `codex` 로그인 필요"
        }
        var line = "~/.codex/auth.json 에서 읽음"
        line += auth.accountID.isEmpty ? " (account_id 없음)" : ""
        if let exp = tokenExpiry(auth.accessToken) {
            let hours = exp.timeIntervalSinceNow / 3600
            line += hours > 0
                ? String(format: " (토큰 만료 %.1f일 후)", hours / 24)
                : String(format: " (토큰 만료됨 — codex 한 번 실행 필요)")
        }
        return line
    }

    /// `exp` claim of the JWT access token. Signature is not verified — this is
    /// only used to explain a 401 to the user, never to authorize anything.
    static func tokenExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                  .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let exp = doubleVal(obj["exp"])
        return exp > 0 ? Date(timeIntervalSince1970: exp) : nil
    }

    /// Last `rate_limits` sample written in a single session file (newest first
    /// within the file), mapped into the two windows it contains.
    static func windows(in file: URL) -> (five: RateWindow?, week: RateWindow?)? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var last: [String: Any]?
        for line in content.split(separator: "\n") {
            guard line.contains("rate_limits") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any]
            else { continue }
            last = rl
        }
        guard let rl = last else { return nil }
        return parseRateLimits(rl)
    }

    /// Maps a raw `rate_limits` object into 5h / weekly windows by
    /// `window_minutes` (300 = 5h, 10080 = weekly). Pure — unit-testable.
    static func parseRateLimits(_ rl: [String: Any]) -> (five: RateWindow?, week: RateWindow?) {
        var five: RateWindow?
        var week: RateWindow?
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any] else { continue }
            let minutes = intVal(w["window_minutes"])
            let win = RateWindow(
                window: minutes == 300 ? .fiveHour : .weekly,
                usedPercent: doubleVal(w["used_percent"]),
                resetsAt: Date(timeIntervalSince1970: doubleVal(w["resets_at"]))
            )
            if minutes == 300 { five = win } else if minutes == 10080 { week = win }
        }
        return (five, week)
    }

    /// Codex reports whichever limit is currently binding as `primary`, so a
    /// single session may omit the 5h or weekly window. We walk recent sessions
    /// newest-first and take, for each window, the most recent sample whose reset
    /// still lies in the future (i.e. describes the window that is live now).
    public static func latest(scanLimit: Int = 40) -> ProviderUsage {
        let files = rolloutFilesNewestFirst(limit: scanLimit)
        guard let newestMod = files.first?.modified else {
            return ProviderUsage(provider: .codex, fiveHour: nil, weekly: nil,
                                 sampledAt: Date(), error: "no session logs found")
        }

        let now = Date()
        var five: RateWindow?
        var week: RateWindow?
        for (url, _) in files {
            guard let w = windows(in: url) else { continue }
            if five == nil, let f = w.five, f.resetsAt > now { five = f }
            if week == nil, let k = w.week, k.resetsAt > now { week = k }
            if five != nil && week != nil { break }
        }

        let err = (five == nil && week == nil) ? "no rate_limits in recent sessions" : nil
        return ProviderUsage(provider: .codex, fiveHour: five, weekly: week,
                             sampledAt: newestMod, error: err)
    }
}

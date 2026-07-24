import Foundation
import Security

/// Reads Claude subscription usage from the authenticated OAuth usage endpoint.
/// The 5h/weekly utilization Claude shows in `/usage` is not written to local
/// files, so we call `GET /api/oauth/usage` with the Bearer token that Claude
/// Code keeps refreshed. The endpoint rate limits aggressively without a
/// `claude-code/<version>` User-Agent, so poll no more than ~once per 3 minutes.
public enum ClaudeReader {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Service name Claude Code uses for its login keychain entry.
    static let keychainService = "Claude Code-credentials"

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// Where the token came from, or why neither store yielded one. The failure
    /// case carries enough detail to diagnose a machine remotely — a generic
    /// "not authenticated" told us nothing when this broke on a second Mac.
    enum CredentialLookup {
        case found(Data, source: String)
        case missing(fileExists: Bool, keychainStatus: OSStatus)
    }

    /// Claude Code stores its OAuth tokens in the **login keychain** on macOS;
    /// only some installs also leave a `~/.claude/.credentials.json` behind. Try
    /// the file first (no auth prompt) and fall back to the keychain, otherwise a
    /// machine that is perfectly well logged in reports "not authenticated".
    /// The keychain read asks the user to allow access the first time — and again
    /// after a new release re-signs the app, since ad-hoc signing changes its
    /// code identity.
    static func loadCredentials() -> CredentialLookup {
        let fileExists = FileManager.default.fileExists(atPath: credentialsURL.path)
        if let data = try? Data(contentsOf: credentialsURL) {
            return .found(data, source: "file")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return .found(data, source: "keychain")
        }
        return .missing(fileExists: fileExists, keychainStatus: status)
    }

    /// Human-readable reason, shown in the menu when no token is available.
    static func missingCredentialsMessage(fileExists: Bool, keychainStatus: OSStatus) -> String {
        let reason: String
        switch keychainStatus {
        case errSecItemNotFound:
            reason = "키체인에 '\(keychainService)' 항목 없음"
        case errSecInteractionNotAllowed:
            reason = "키체인 접근에 사용자 승인이 필요함 (앱을 다시 실행해 '허용'을 선택)"
        case errSecAuthFailed, errSecUserCanceled:
            reason = "키체인 접근이 거부됨 (키체인 접근 앱에서 '\(keychainService)' 권한 확인)"
        default:
            reason = "키체인 읽기 실패 (OSStatus \(keychainStatus))"
        }
        let file = fileExists ? "credentials.json은 있으나 읽지 못함" : "~/.claude/.credentials.json 없음"
        return "인증 정보 없음 — \(file); \(reason)"
    }

    /// One-line summary for `usage-probe`. Reveals no token material.
    public static func diagnosticCredentialSource() -> String {
        switch loadCredentials() {
        case let .found(data, source):
            let ok = parseToken(from: data) != nil
            return "\(source)에서 찾음 (토큰 파싱: \(ok ? "성공" : "실패"))"
        case let .missing(fileExists, status):
            return missingCredentialsMessage(fileExists: fileExists, keychainStatus: status)
        }
    }

    /// The token is read fresh on every call so we always use the value Claude
    /// Code most recently refreshed, and it never lives anywhere but memory.
    static func accessToken() -> String? {
        guard case let .found(data, _) = loadCredentials() else { return nil }
        return parseToken(from: data)
    }

    /// Both stores hold the same `{"claudeAiOauth": {"accessToken": …}}` shape,
    /// but tolerate a bare token string in case the keychain item is stored raw.
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

    /// Synchronous fetch (blocks the calling thread). Call off the main thread.
    public static func fetch(timeout: TimeInterval = 15) -> ProviderUsage {
        let token: String
        switch loadCredentials() {
        case let .found(data, _):
            guard let parsed = parseToken(from: data) else {
                return ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil, sampledAt: Date(),
                                     error: "인증 정보를 해석하지 못함 — Claude Code 재로그인 필요")
            }
            token = parsed
        case let .missing(fileExists, status):
            return ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil, sampledAt: Date(),
                                 error: missingCredentialsMessage(fileExists: fileExists,
                                                                  keychainStatus: status))
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("claude-code/\(claudeCodeVersion())", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, err in
            defer { sem.signal() }
            if let err {
                box.value = ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil,
                                          sampledAt: Date(), error: err.localizedDescription)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                box.value = ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil,
                                          sampledAt: Date(), error: "empty response (HTTP \(status))")
                return
            }
            if status == 429 {
                box.value = ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil,
                                          sampledAt: Date(), error: "rate limited (429) — polling too fast")
                return
            }
            guard status == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                box.value = ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil,
                                          sampledAt: Date(), error: "HTTP \(status)")
                return
            }
            box.value = parse(obj)
        }.resume()

        _ = sem.wait(timeout: .now() + timeout + 2)
        return box.value ?? ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil,
                                          sampledAt: Date(), error: "timed out")
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

final class ResultBox: @unchecked Sendable {
    var value: ProviderUsage?
}

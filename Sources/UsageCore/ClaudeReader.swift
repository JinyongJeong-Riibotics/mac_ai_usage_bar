import CryptoKit
import Foundation

/// Reads Claude subscription usage from the authenticated OAuth usage endpoint.
///
/// Claude Code isolates accounts with `CLAUDE_CONFIG_DIR`. On macOS, custom
/// config directories also get a directory-specific keychain service. The app
/// mirrors that lookup, but never writes or refreshes credentials itself:
/// Claude Code remains the sole credential writer and is invoked for a small
/// `claude -p ok` request only when a profile needs its token refreshed.
public enum ClaudeReader {
    public static let defaultConfigDirectoryPath = "~/.claude"

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let defaultKeychainService = "Claude Code-credentials"

    /// Expand and standardize a configured path exactly once. The resulting
    /// absolute, NFC-normalized string is used both for `CLAUDE_CONFIG_DIR` and
    /// for the keychain-service hash, so the two can never drift apart.
    public static func resolvedConfigDirectory(
        for configuredPath: String = defaultConfigDirectoryPath
    ) -> URL {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? defaultConfigDirectoryPath : trimmed
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute: String
        if (expanded as NSString).isAbsolutePath {
            absolute = expanded
        } else {
            absolute = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                           isDirectory: true)
                .appendingPathComponent(expanded, isDirectory: true).path
        }
        let standardized = URL(fileURLWithPath: absolute, isDirectory: true)
            .standardizedFileURL.path.precomposedStringWithCanonicalMapping
        return URL(fileURLWithPath: standardized, isDirectory: true)
    }

    static var defaultConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .standardizedFileURL
    }

    static func isDefaultConfigDirectory(_ configuredPath: String) -> Bool {
        resolvedConfigDirectory(for: configuredPath).path
            == defaultConfigDirectory.path.precomposedStringWithCanonicalMapping
    }

    static func credentialsURL(configDirectoryPath: String) -> URL {
        resolvedConfigDirectory(for: configDirectoryPath)
            .appendingPathComponent(".credentials.json", isDirectory: false)
    }

    /// Claude Code 2.1.x appends the first eight SHA-256 hex characters of the
    /// normalized absolute config-directory path for non-default profiles.
    static func keychainService(configDirectoryPath: String) -> String {
        guard !isDefaultConfigDirectory(configDirectoryPath) else {
            return defaultKeychainService
        }
        let path = resolvedConfigDirectory(for: configDirectoryPath).path
            .precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(defaultKeychainService)-\(suffix)"
    }

    /// Read the token from the freshest store for one Claude profile. Claude
    /// may use either the profile's `.credentials.json` fallback or its macOS
    /// keychain entry, so both remain supported without copying between them.
    static func loadCredentials(
        configDirectoryPath: String = defaultConfigDirectoryPath,
        forceKeychainRead: Bool = false
    ) -> (data: Data, source: String)? {
        let fileURL = credentialsURL(configDirectoryPath: configDirectoryPath)
        let fileData = (try? Data(contentsOf: fileURL))
            .flatMap { parseToken(from: $0) != nil ? $0 : nil }
        let fileExpiry = fileData.flatMap { expiresAt(from: $0) } ?? .distantPast

        var keychainData: Data?
        if forceKeychainRead || fileData == nil || fileExpiry.timeIntervalSinceNow < 1800 {
            let service = keychainService(configDirectoryPath: configDirectoryPath)
            if let raw = runCommand("/usr/bin/security",
                                    ["find-generic-password", "-s", service, "-w"]),
               let data = raw.data(using: .utf8), parseToken(from: data) != nil {
                keychainData = data
            }
        }
        let keychainExpiry = keychainData.flatMap { expiresAt(from: $0) } ?? .distantPast

        // Ties go to the file to avoid an unnecessary keychain access prompt.
        if let fileData, fileExpiry >= keychainExpiry { return (fileData, "file") }
        if let keychainData { return (keychainData, "keychain") }
        if let fileData { return (fileData, "file") }
        return nil
    }

    /// Diagnostic summary for `usage-probe`; never includes token values.
    public static func diagnosticCredentialSource(
        configDirectoryPath: String = defaultConfigDirectoryPath
    ) -> String {
        func expiryText(_ data: Data?) -> String {
            guard let data, parseToken(from: data) != nil else { return "없음/해석불가" }
            guard let expiry = expiresAt(from: data) else { return "만료시각 미상" }
            let hours = expiry.timeIntervalSinceNow / 3600
            return hours > 0
                ? String(format: "만료 %.1fh 후", hours)
                : String(format: "%.1fh 전 만료", -hours)
        }

        let fileURL = credentialsURL(configDirectoryPath: configDirectoryPath)
        let service = keychainService(configDirectoryPath: configDirectoryPath)
        let fileData = try? Data(contentsOf: fileURL)
        let keychainData = runCommand("/usr/bin/security",
            ["find-generic-password", "-s", service, "-w"])?.data(using: .utf8)

        guard let (chosen, source) = loadCredentials(configDirectoryPath: configDirectoryPath) else {
            return "\(resolvedConfigDirectory(for: configDirectoryPath).path) · 파일·키체인 없음"
        }
        return "\(resolvedConfigDirectory(for: configDirectoryPath).path) · 사용: \(source) "
            + "(\(expiryText(chosen))) | 파일: \(expiryText(fileData)) | "
            + "키체인: \(expiryText(keychainData))"
    }

    // MARK: - Refresh via the Claude Code CLI

    private static let cliRefreshLock = NSLock()
    nonisolated(unsafe) static var lastCLIRefreshByProfile: [String: Date] = [:]
    private static let versionLock = NSLock()
    nonisolated(unsafe) static var cachedClaudeCodeVersion: String?

    public static func diagnosticClaudeBinary() -> String {
        locateClaudeBinary() ?? "claude 실행파일 못 찾음 (터미널 없이 갱신 불가)"
    }

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
        return nil
    }

    /// Remove ambient authentication/provider overrides before selecting the
    /// requested profile. The default profile deliberately leaves
    /// `CLAUDE_CONFIG_DIR` unset so existing `Claude Code-credentials` logins
    /// keep working; custom profiles receive their normalized absolute path.
    static func claudeEnvironment(
        configDirectoryPath: String,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = minimalProcessEnvironment(inherited: inherited)
        environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
        environment["NO_COLOR"] = "1"
        if isDefaultConfigDirectory(configDirectoryPath) {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            environment["CLAUDE_CONFIG_DIR"] = resolvedConfigDirectory(
                for: configDirectoryPath
            ).path
        }
        return environment
    }

    /// A token refresh needs one model response and no local capabilities.
    /// Safe/restricted mode prevents user/project settings, hooks, plugins,
    /// skills and MCP servers from loading; the remaining flags disable tools,
    /// Chrome integration, persistence, and unattended permission prompts.
    static func cliRefreshArguments() -> [String] {
        [
            "--safe-mode",
            "--restricted",
            "--tools", "",
            "--disallowedTools", "mcp__*",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-chrome",
            "--no-session-persistence",
            "--permission-prompts", "none",
            "-p", "ok",
        ]
    }

    /// Ask Claude Code to refresh exactly one profile. Each profile has its own
    /// 30-minute throttle so a failing account cannot suppress another account.
    @discardableResult
    static func triggerCLIRefresh(configDirectoryPath: String = defaultConfigDirectoryPath,
                                  now: Date = Date(),
                                  timeout: TimeInterval = 45) -> Bool {
        guard let claude = locateClaudeBinary() else { return false }
        let profileKey = resolvedConfigDirectory(for: configDirectoryPath).path
        cliRefreshLock.lock()
        if let last = lastCLIRefreshByProfile[profileKey], now.timeIntervalSince(last) < 1800 {
            cliRefreshLock.unlock()
            return false
        }
        lastCLIRefreshByProfile[profileKey] = now
        cliRefreshLock.unlock()

        return runCommand(claude, cliRefreshArguments(), timeout: timeout,
                          environment: claudeEnvironment(
                            configDirectoryPath: configDirectoryPath
                          )) != nil
    }

    /// `expiresAt` is epoch milliseconds; used only to explain authentication
    /// failures without revealing credential contents.
    static func expiresAt(from data: Data) -> Date? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        let milliseconds = doubleVal(oauth["expiresAt"])
        return milliseconds > 0
            ? Date(timeIntervalSince1970: milliseconds / 1000)
            : nil
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

    /// Best-effort version for the usage User-Agent. Query the executable once
    /// instead of recursively scanning every profile's project transcripts.
    static func claudeCodeVersion() -> String {
        versionLock.lock()
        defer { versionLock.unlock() }
        if let cachedClaudeCodeVersion { return cachedClaudeCodeVersion }

        let detected = locateClaudeBinary()
            .flatMap { runCommand($0, ["--version"], timeout: 5) }
            .flatMap(parseClaudeVersion)
            ?? "2.1.0"
        cachedClaudeCodeVersion = detected
        return detected
    }

    static func parseClaudeVersion(_ output: String) -> String? {
        guard let candidate = output.split(whereSeparator: { $0.isWhitespace }).first else {
            return nil
        }
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return String(candidate)
    }

    static func makeISO() -> [ISO8601DateFormatter] {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractionalSeconds, plain]
    }

    static func parseDate(_ string: String?, _ formatters: [ISO8601DateFormatter]) -> Date? {
        guard let string else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    static func failure(_ message: String) -> ProviderUsage {
        ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil,
                      sampledAt: Date(), error: message)
    }

    /// Synchronous fetch for one profile. Call from a detached task.
    public static func fetch(configDirectoryPath: String = defaultConfigDirectoryPath,
                             timeout: TimeInterval = 15,
                             cliRefresh: Bool = false) -> ProviderUsage {
        var loaded = loadCredentials(configDirectoryPath: configDirectoryPath)
        if loaded == nil,
           cliRefresh,
           triggerCLIRefresh(configDirectoryPath: configDirectoryPath) {
            loaded = loadCredentials(configDirectoryPath: configDirectoryPath,
                                     forceKeychainRead: true)
        }
        guard let (data, _) = loaded else {
            return failure("Claude 인증 정보 없음 — 설정의 로그인 명령을 실행하세요")
        }
        guard let token = parseToken(from: data) else {
            return failure("인증 정보를 해석하지 못함 — 이 Claude 계정을 다시 로그인하세요")
        }

        let result = requestUsage(token: token, timeout: timeout)
        if case let .authFailed(status) = result {
            if cliRefresh,
               triggerCLIRefresh(configDirectoryPath: configDirectoryPath),
               let (freshData, _) = loadCredentials(configDirectoryPath: configDirectoryPath,
                                                     forceKeychainRead: true),
               let freshToken = parseToken(from: freshData) {
                return requestUsage(token: freshToken, timeout: timeout)
                    .toProviderUsage(dataForExpiry: freshData)
            }
            if let expiry = expiresAt(from: data), expiry < Date() {
                return failure("토큰 만료 — 이 Claude 계정의 자동 갱신 또는 재로그인이 필요합니다")
            }
            return failure("인증 거부됨 (HTTP \(status)) — 이 Claude 계정을 다시 로그인하세요")
        }
        return result.toProviderUsage(dataForExpiry: data)
    }

    private enum UsageResult {
        case ok([String: Any])
        case authFailed(Int)
        case rateLimited
        case transport(String)
        case http(Int)

        func toProviderUsage(dataForExpiry: Data?) -> ProviderUsage {
            switch self {
            case let .ok(object): return parse(object)
            case let .authFailed(status):
                if let dataForExpiry,
                   let expiry = expiresAt(from: dataForExpiry), expiry < Date() {
                    return failure("토큰 만료 — 자동 갱신 실패. 이 Claude 계정을 다시 로그인하세요")
                }
                return failure("인증 거부됨 (HTTP \(status)) — 이 Claude 계정을 다시 로그인하세요")
            case .rateLimited: return failure("rate limited (429) — polling too fast")
            case let .transport(message): return failure(message)
            case let .http(status): return failure("HTTP \(status)")
            }
        }
    }

    private static func requestUsage(token: String,
                                     timeout: TimeInterval) -> UsageResult {
        let response = HTTP.get(usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "User-Agent": "claude-code/\(claudeCodeVersion())",
            "Content-Type": "application/json",
        ], timeout: timeout)

        if let transport = response.transportError { return .transport(transport) }
        switch response.status {
        case 200:
            guard let data = response.data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .http(200) }
            return .ok(object)
        case 401, 403: return .authFailed(response.status)
        case 429: return .rateLimited
        default: return .http(response.status)
        }
    }

    static func parse(_ object: [String: Any]) -> ProviderUsage {
        let formatters = makeISO()
        func window(_ key: String, _ usageWindow: UsageWindow) -> RateWindow? {
            guard let dictionary = object[key] as? [String: Any],
                  let reset = parseDate(dictionary["resets_at"] as? String, formatters)
            else { return nil }
            return RateWindow(window: usageWindow,
                              usedPercent: doubleVal(dictionary["utilization"]),
                              resetsAt: reset)
        }
        return ProviderUsage(
            provider: .claude,
            fiveHour: window("five_hour", .fiveHour),
            weekly: window("seven_day", .weekly),
            sampledAt: Date()
        )
    }
}

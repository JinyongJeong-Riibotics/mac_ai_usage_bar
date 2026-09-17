import Foundation

/// Reads Codex usage through the official `codex app-server` protocol.
///
/// Each account gets its own `CODEX_HOME`, which isolates configuration and
/// credentials. The CLI is forced to use file-backed credentials so multiple
/// profiles cannot collapse onto one shared macOS keychain entry.
public enum CodexReader {
    public static let defaultHomePath = "~/.codex"

    /// Fetch the limits for one Codex profile. This method is synchronous by
    /// design; callers run it on a detached utility task.
    public static func fetch(codexHomePath: String = defaultHomePath,
                             timeout: TimeInterval = 15) -> ProviderUsage {
        let now = Date()
        let trimmed = codexHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return failure("CODEX_HOME 경로가 비어 있음", sampledAt: now)
        }

        let home = resolveHomePath(trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return failure("CODEX_HOME 폴더 없음: \(home.path) · 설정에서 로그인 명령을 실행하세요",
                           sampledAt: now)
        }
        guard let executable = codexExecutablePath() else {
            return failure("codex 실행파일을 찾지 못함", sampledAt: now)
        }

        switch requestRateLimits(executable: executable, codexHome: home, timeout: timeout) {
        case let .success(message):
            guard let usage = parseAppServerResponse(message, now: now) else {
                return failure("Codex 한도 응답을 해석하지 못함", sampledAt: now)
            }
            return usage
        case let .failure(error):
            return failure(error.description, sampledAt: now)
        }
    }

    /// Expands `~` exactly as the CLI setup command shown by the app does.
    public static func resolveHomePath(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    /// Diagnostic text for `usage-probe`; it deliberately reveals no tokens.
    public static func diagnosticProfile(_ codexHomePath: String = defaultHomePath) -> String {
        let home = resolveHomePath(codexHomePath)
        let auth = home.appendingPathComponent("auth.json")
        let authStatus = FileManager.default.fileExists(atPath: auth.path)
            ? "auth.json 있음"
            : "auth.json 없음"
        return "\(home.path) (\(authStatus))"
    }

    public static func diagnosticCodexBinary() -> String {
        codexExecutablePath() ?? "찾지 못함"
    }

    /// Pure parser for the JSON-RPC response to `account/rateLimits/read`.
    /// Prefer the named `codex` bucket because the protocol may expose other
    /// limits alongside it; fall back to the compatibility `rateLimits` field.
    static func parseAppServerResponse(_ message: [String: Any],
                                       now: Date = Date()) -> ProviderUsage? {
        guard let result = message["result"] as? [String: Any] else { return nil }
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let limits = (byID?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any])
        guard let limits else { return nil }

        var fiveHour: RateWindow?
        var weekly: RateWindow?
        for key in ["primary", "secondary"] {
            guard let object = limits[key] as? [String: Any],
                  let window = parseAppServerWindow(object)
            else { continue }
            switch window.window {
            case .fiveHour: fiveHour = window
            case .weekly: weekly = window
            }
        }

        let resetCreditCount: Int?
        if let summary = result["rateLimitResetCredits"] as? [String: Any],
           let rawCount = summary["availableCount"],
           !(rawCount is NSNull) {
            resetCreditCount = max(0, intVal(rawCount))
        } else {
            resetCreditCount = nil
        }

        guard fiveHour != nil || weekly != nil else { return nil }
        return ProviderUsage(provider: .codex,
                             fiveHour: fiveHour,
                             weekly: weekly,
                             rateLimitResetCredits: resetCreditCount,
                             sampledAt: now)
    }

    static func parseAppServerWindow(_ object: [String: Any]) -> RateWindow? {
        let minutes = intVal(object["windowDurationMins"])
        let resetEpoch = doubleVal(object["resetsAt"])
        guard minutes > 0, resetEpoch > 0 else { return nil }

        // Current Codex plans expose 300-minute and 10,080-minute windows. Keep
        // the pre-existing UI's shorter/longer fallback for compatible plans.
        let window: UsageWindow = minutes <= 1440 ? .fiveHour : .weekly
        return RateWindow(window: window,
                          usedPercent: doubleVal(object["usedPercent"]),
                          resetsAt: Date(timeIntervalSince1970: resetEpoch))
    }

    private static func failure(_ message: String, sampledAt: Date) -> ProviderUsage {
        ProviderUsage(provider: .codex,
                      fiveHour: nil,
                      weekly: nil,
                      sampledAt: sampledAt,
                      error: message)
    }

    private enum AppServerError: Error {
        case launch(String)
        case initializeTimeout
        case initialize(String)
        case requestTimeout
        case request(String)

        var description: String {
            switch self {
            case let .launch(message): return "Codex App Server 실행 실패: \(message)"
            case .initializeTimeout: return "Codex App Server 초기화 시간 초과"
            case let .initialize(message): return "Codex App Server 초기화 실패: \(message)"
            case .requestTimeout: return "Codex 한도 조회 시간 초과"
            case let .request(message): return "Codex 한도 조회 실패: \(message)"
            }
        }
    }

    private static func requestRateLimits(executable: String,
                                          codexHome: URL,
                                          timeout: TimeInterval)
        -> Result<[String: Any], AppServerError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "-c", "cli_auth_credentials_store=\"file\""]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment["CODEX_SQLITE_HOME"] = codexHome.path
        environment["PATH"] = augmentedPath(
            executablePath: executable,
            inheritedPath: environment["PATH"]
        )
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        let collector = AppServerOutputCollector()
        let errorCollector = ProcessTextCollector()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.consume(data) }
        }
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errorCollector.consume(data) }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            return .failure(.launch(error.localizedDescription))
        }

        defer {
            try? input.fileHandleForWriting.close()
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        do {
            try writeJSONLine([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "mac_ai_usage_bar",
                        "title": "Mac AI Usage Bar",
                        "version": "1",
                    ],
                ],
            ], to: input.fileHandleForWriting)
        } catch {
            return .failure(.launch(error.localizedDescription))
        }

        switch wait(for: collector.initializeSignal, process: process, timeout: timeout) {
        case .signaled: break
        case .exited:
            return .failure(.initialize(errorCollector.text ?? "codex 프로세스가 응답 없이 종료됨"))
        case .timedOut:
            return .failure(.initializeTimeout)
        }
        if let message = collector.errorMessage(for: 1) {
            return .failure(.initialize(message))
        }

        do {
            try writeJSONLine(["method": "initialized", "params": [:]],
                              to: input.fileHandleForWriting)
            try writeJSONLine(["method": "account/rateLimits/read", "id": 2],
                              to: input.fileHandleForWriting)
        } catch {
            return .failure(.request(error.localizedDescription))
        }

        switch wait(for: collector.rateLimitsSignal, process: process, timeout: timeout) {
        case .signaled: break
        case .exited:
            return .failure(.request(errorCollector.text ?? "codex 프로세스가 응답 없이 종료됨"))
        case .timedOut:
            return .failure(.requestTimeout)
        }
        if let message = collector.errorMessage(for: 2) {
            return .failure(.request(message))
        }
        guard let response = collector.response(for: 2) else {
            return .failure(.request("빈 응답"))
        }
        return .success(response)
    }

    private static func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    /// GUI apps launched by Finder/login items inherit a minimal PATH. Homebrew's
    /// `codex` is commonly a `#!/usr/bin/env node` script, so its own directory
    /// must be present for `env` to find the adjacent Node runtime.
    static func augmentedPath(executablePath: String, inheritedPath: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = [
            URL(fileURLWithPath: executablePath).deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        if let inheritedPath {
            directories.append(contentsOf: inheritedPath.split(separator: ":").map(String.init))
        }

        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private enum SignalWaitResult {
        case signaled
        case exited
        case timedOut
    }

    private static func wait(for signal: DispatchSemaphore,
                             process: Process,
                             timeout: TimeInterval) -> SignalWaitResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if signal.wait(timeout: .now() + 0.1) == .success { return .signaled }
            if !process.isRunning { return .exited }
        }
        return .timedOut
    }

    private static func codexExecutablePath() -> String? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.codex/bin/codex",
        ])

        var seen = Set<String>()
        return candidates.first { path in
            seen.insert(path).inserted && FileManager.default.isExecutableFile(atPath: path)
        }
    }
}

private final class ProcessTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func consume(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > 16_384 { data = data.suffix(16_384) }
    }

    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// `FileHandle.readabilityHandler` runs on a Foundation-managed queue. Keep all
/// mutable parser state behind a lock and expose only semaphore-based handoffs
/// to the synchronous reader above.
private final class AppServerOutputCollector: @unchecked Sendable {
    let initializeSignal = DispatchSemaphore(value: 0)
    let rateLimitsSignal = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var signaledIDs = Set<Int>()

    func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var completed: [Int] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            let id = intVal(object["id"])
            guard id == 1 || id == 2 else { continue }
            responses[id] = object
            if signaledIDs.insert(id).inserted { completed.append(id) }
        }
        lock.unlock()

        for id in completed {
            if id == 1 { initializeSignal.signal() }
            if id == 2 { rateLimitsSignal.signal() }
        }
    }

    func response(for id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return responses[id]
    }

    func errorMessage(for id: Int) -> String? {
        guard let error = response(for: id)?["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "알 수 없는 JSON-RPC 오류"
    }
}

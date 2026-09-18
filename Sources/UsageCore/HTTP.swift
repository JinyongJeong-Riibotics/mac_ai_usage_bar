import Foundation

/// Minimal synchronous GET shared by both readers. They poll from a detached
/// task, so blocking the calling thread is fine and keeps the call sites free of
/// the semaphore dance.
enum HTTP {
    struct Response {
        let status: Int
        let data: Data?
        /// Transport-level failure (offline, DNS, timeout). `nil` on any HTTP reply.
        let transportError: String?
    }

    static func get(_ url: URL,
                    headers: [String: String],
                    timeout: TimeInterval) -> Response {
        send(url, method: "GET", headers: headers, body: nil, timeout: timeout)
    }

    private static func send(_ url: URL,
                             method: String,
                             headers: [String: String],
                             body: Data?,
                             timeout: TimeInterval) -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        request.timeoutInterval = timeout

        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, err in
            defer { sem.signal() }
            if let err {
                box.value = Response(status: 0, data: nil, transportError: err.localizedDescription)
                return
            }
            box.value = Response(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                 data: data, transportError: nil)
        }.resume()

        _ = sem.wait(timeout: .now() + timeout + 2)
        return box.value ?? Response(status: 0, data: nil, transportError: "timed out")
    }
}

final class ResponseBox: @unchecked Sendable {
    var value: HTTP.Response?
}

/// Only pass environment values a provider CLI needs. In particular, never
/// forward PWD/OLDPWD, editor/plugin variables, or unrelated credentials from
/// the process that happened to launch the menu-bar app.
func minimalProcessEnvironment(
    inherited: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    let allowedKeys: Set<String> = [
        "HOME", "PATH", "SHELL", "TMPDIR", "USER", "LOGNAME",
        "LANG", "LC_ALL", "LC_CTYPE", "TZ", "NO_COLOR",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
    ]
    return inherited.filter { allowedKeys.contains($0.key) }
}

/// A neutral directory that cannot inherit a user project, Desktop, Documents,
/// Downloads, or media folder as a child process's working context.
func safeProcessWorkingDirectory() -> URL {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
}

/// Runs a command and returns its trimmed stdout, or nil on non-zero exit / no
/// output. Every child starts in a neutral temporary directory with a minimal
/// environment unless a stricter provider-specific environment is supplied.
func runCommand(_ path: String,
                _ args: [String],
                timeout: TimeInterval = 10,
                environment: [String: String]? = nil,
                workingDirectory: URL = safeProcessWorkingDirectory()) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.environment = environment ?? minimalProcessEnvironment()
    process.currentDirectoryURL = workingDirectory
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }

    // Guard against a hung child (e.g. a keychain dialog nobody answers).
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning { process.terminate(); return nil }

    let data = out.fileHandleForReading.readDataToEndOfFile()
    let s = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (process.terminationStatus == 0 && !s.isEmpty) ? s : nil
}

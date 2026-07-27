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

    /// Form-encoded POST, used for the OAuth token refresh.
    static func postForm(_ url: URL,
                         fields: [String: String],
                         headers: [String: String] = [:],
                         timeout: TimeInterval) -> Response {
        let body = fields.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&").data(using: .utf8)
        var h = headers
        h["Content-Type"] = "application/x-www-form-urlencoded"
        return send(url, method: "POST", headers: h, body: body, timeout: timeout)
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
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

/// Reads a CLI's credentials file. Both Codex and Claude Code keep their tokens
/// in a `0600` JSON file under the home directory, which is exactly the
/// terminal login we want to reuse — no keychain, no prompts.
func readJSONFile(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

/// Runs a command and returns its trimmed stdout, or nil on non-zero exit / no
/// output. Used to read a login-keychain item through Apple's `/usr/bin/security`
/// tool: because `security` has a stable Apple code signature, the one-time
/// "Always Allow" the user grants sticks across our (ad-hoc, ever-changing) app
/// signature — reading the item in-process would re-prompt after every update.
func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
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

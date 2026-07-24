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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
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

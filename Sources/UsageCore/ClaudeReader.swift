import Foundation

/// Reads Claude subscription usage from the authenticated OAuth usage endpoint.
/// The 5h/weekly utilization Claude shows in `/usage` is not written to local
/// files, so we call `GET /api/oauth/usage` with the Bearer token that Claude
/// Code keeps refreshed in `~/.claude/.credentials.json`. The endpoint rate
/// limits aggressively without a `claude-code/<version>` User-Agent, so poll no
/// more than ~once per 3 minutes.
public enum ClaudeReader {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// The token is read fresh on every call so we always use the value Claude
    /// Code most recently refreshed, and it never lives anywhere but memory.
    static func accessToken() -> String? {
        guard let data = try? Data(contentsOf: credentialsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        return token
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
        guard let token = accessToken() else {
            return ProviderUsage(provider: .claude, fiveHour: nil, weekly: nil,
                                 sampledAt: Date(), error: "no credentials — is Claude Code logged in?")
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

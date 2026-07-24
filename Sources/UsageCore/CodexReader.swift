import Foundation

/// Reads Codex usage from the local session rollout logs. Codex writes a
/// `token_count` event carrying `rate_limits` (5h + weekly windows) into the
/// newest `~/.codex/sessions/**/rollout-*.jsonl`; no network call is needed.
public enum CodexReader {
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
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

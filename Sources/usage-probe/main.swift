import Foundation
import UsageCore

func fmtReset(_ interval: TimeInterval) -> String {
    if interval <= 0 { return "now" }
    let total = Int(interval)
    let d = total / 86400
    let h = (total % 86400) / 3600
    let m = (total % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func printWindow(_ label: String, _ w: RateWindow?) {
    guard let w else {
        print("  \(label.padding(toLength: 8, withPad: " ", startingAt: 0)) —")
        return
    }
    let pct = String(format: "%5.1f%%", w.usedPercent)
    print("  \(label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(pct) used   resets in \(fmtReset(w.timeUntilReset))")
}

func report(_ u: ProviderUsage) {
    print("========== \(u.provider.rawValue) ==========")
    if let e = u.error {
        print("  error: \(e)")
    }
    printWindow("5h", u.fiveHour)
    printWindow("Weekly", u.weekly)
    let age = Date().timeIntervalSince(u.sampledAt)
    print("  sampled: \(fmtReset(age)) 전")
    print()
}

/// Where each provider's data comes from, so a machine that reports the wrong
/// numbers can be diagnosed without guessing. Prints no secrets — only whether
/// a token was found and from which store.
func environmentReport() {
    print("========== 환경 ==========")
    let home = FileManager.default.homeDirectoryForCurrentUser
    print("  home: \(home.path)")

    print("  codex 인증:   \(CodexReader.diagnosticAuthSource())")
    print("  codex 폴백 로그: \(CodexReader.diagnosticSessionCount())개")
    print("  claude 인증:  \(ClaudeReader.diagnosticCredentialSource())")
    print()
}

environmentReport()
report(CodexReader.fetch())
report(ClaudeReader.fetch())

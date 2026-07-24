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
    print()
}

report(CodexReader.latest())
report(ClaudeReader.fetch())

import Foundation

public func formatReset(_ interval: TimeInterval) -> String {
    if interval <= 0 { return "now" }
    let total = Int(interval)
    let d = total / 86400
    let h = (total % 86400) / 3600
    let m = (total % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

public func formatPercent(_ value: Double) -> String {
    String(format: "%.0f%%", value)
}

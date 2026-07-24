import Foundation

public enum UsageWindow: Sendable, Hashable {
    case fiveHour
    case weekly

    public var label: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "Weekly"
        }
    }
}

public struct RateWindow: Sendable, Hashable {
    public let window: UsageWindow
    public let usedPercent: Double
    public let resetsAt: Date

    public init(window: UsageWindow, usedPercent: Double, resetsAt: Date) {
        self.window = window
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var timeUntilReset: TimeInterval { resetsAt.timeIntervalSinceNow }
}

public enum Provider: String, Sendable {
    case codex = "Codex"
    case claude = "Claude"
}

public struct ProviderUsage: Sendable {
    public let provider: Provider
    public let fiveHour: RateWindow?
    public let weekly: RateWindow?
    public let sampledAt: Date
    public let error: String?

    public init(provider: Provider,
                fiveHour: RateWindow?,
                weekly: RateWindow?,
                sampledAt: Date,
                error: String? = nil) {
        self.provider = provider
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.sampledAt = sampledAt
        self.error = error
    }
}

func intVal(_ v: Any?) -> Int {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(d) }
    if let n = v as? NSNumber { return n.intValue }
    return 0
}

func doubleVal(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return 0
}

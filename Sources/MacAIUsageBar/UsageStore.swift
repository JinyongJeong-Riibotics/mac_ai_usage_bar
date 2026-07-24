import Foundation
import Combine
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published var codex: ProviderUsage?
    @Published var claude: ProviderUsage?
    @Published var claudeNotice: String?
    @Published var lastRefresh: Date?

    private let settings = AppSettings.shared
    private let notifier = UsageNotifier()
    private var codexTimer: Timer?
    private var claudeTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Multiplies the Claude interval after a 429 so we back off automatically,
    // resetting to 1 on the next success. Capped so we never stall forever.
    private var claudeBackoff: Double = 1
    private let maxBackoff: Double = 8

    func start() {
        notifier.requestAuthIfNeeded()
        refreshCodex()
        refreshClaude()
        scheduleCodex()
        scheduleClaude()

        // Reschedule whenever the user changes an interval in Settings.
        settings.$codexInterval
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleCodex() } }
            .store(in: &cancellables)
        settings.$claudeInterval
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleClaude() } }
            .store(in: &cancellables)
    }

    func refreshAll() {
        refreshCodex()
        refreshClaude()
    }

    private func scheduleCodex() {
        codexTimer?.invalidate()
        let interval = max(AppSettings.codexMinInterval, settings.codexInterval)
        codexTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodex() }
        }
    }

    private func scheduleClaude() {
        claudeTimer?.invalidate()
        let base = max(AppSettings.claudeMinInterval, settings.claudeInterval)
        let interval = base * claudeBackoff
        claudeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshClaude() }
        }
    }

    func refreshCodex() {
        Task.detached(priority: .utility) {
            let usage = CodexReader.fetch()
            await MainActor.run {
                self.codex = usage
                self.lastRefresh = Date()
                self.notifier.evaluate(usage, settings: self.settings)
            }
        }
    }

    func refreshClaude() {
        Task.detached(priority: .utility) {
            let usage = ClaudeReader.fetch()
            await MainActor.run {
                self.lastRefresh = Date()
                // Don't let a transient error (e.g. 429) erase the last good
                // reading — keep showing it and surface the error as a notice.
                if usage.fiveHour != nil || usage.weekly != nil {
                    self.claude = usage
                    self.claudeNotice = nil
                    self.notifier.evaluate(usage, settings: self.settings)
                } else {
                    self.claudeNotice = usage.error
                    if self.claude == nil { self.claude = usage }
                }
                self.handleClaudeResult(usage)
            }
        }
    }

    /// On a 429 we grow the backoff and reschedule further out; any other outcome
    /// resets it. Claude uses a non-repeating timer so each fire re-arms with the
    /// current (possibly backed-off) interval.
    private func handleClaudeResult(_ usage: ProviderUsage) {
        let rateLimited = (usage.error?.contains("429") ?? false)
            || (usage.error?.contains("rate limited") ?? false)
        if rateLimited {
            claudeBackoff = min(maxBackoff, claudeBackoff * 2)
        } else {
            claudeBackoff = 1
        }
        scheduleClaude()
    }

    /// Human-readable current effective Claude cadence, for the settings screen.
    var effectiveClaudeInterval: Double {
        max(AppSettings.claudeMinInterval, settings.claudeInterval) * claudeBackoff
    }

    var isClaudeBackingOff: Bool { claudeBackoff > 1 }
}

/// Displayed percentage for a window given the used/remaining preference.
func displayedPercent(usedPercent: Double, mode: DisplayMode) -> Double {
    mode == .used ? usedPercent : max(0, 100 - usedPercent)
}

/// The window a bar/label should show for a provider, honoring the preferred
/// window but falling back to the other when the preferred one is absent
/// (Codex frequently omits its 5h window in the local logs).
func preferredWindow(_ usage: ProviderUsage?, _ pref: BarWindow) -> RateWindow? {
    guard let usage else { return nil }
    switch pref {
    case .fiveHour: return usage.fiveHour ?? usage.weekly
    case .weekly: return usage.weekly ?? usage.fiveHour
    }
}

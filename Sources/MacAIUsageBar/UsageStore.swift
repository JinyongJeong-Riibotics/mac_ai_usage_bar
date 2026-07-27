import Foundation
import Combine
import AppKit
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

    /// `.onAppear` on the dropdown fires every time the menu opens, so guard the
    /// one-time setup (timers, subscriptions, wake observer) against re-running
    /// — otherwise each open stacked another timer and another auth request.
    private var didStart = false

    // Multiplies the Claude interval after a 429 so we back off automatically,
    // resetting to 1 on the next success. Capped so we never stall forever.
    private var claudeBackoff: Double = 1
    private let maxBackoff: Double = 8

    /// Called from the menu's `.onAppear`. First call wires everything up; every
    /// call (including reopening the menu) refreshes, so the numbers are current
    /// the moment the user looks at them.
    func start() {
        if !didStart {
            didStart = true
            notifier.requestAuthIfNeeded()
            scheduleCodex()
            scheduleClaude()
            observeWake()

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
        refreshAll()
    }

    /// Timers don't fire while the Mac is asleep and don't catch up promptly on
    /// wake, so after opening the lid the menu bar showed the pre-sleep value
    /// until the next scheduled fire. Refresh on wake and restart the cadence
    /// from now. The network is often not up yet at the wake instant, so also
    /// retry shortly after — the first attempt may fall back to stale local logs.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    private func handleWake() {
        // Restart the cadence from now, then refresh — immediately and a couple
        // of times over the next ~15s, since Wi-Fi/VPN often reconnects a few
        // seconds after wake and the first attempt falls back to stale local logs.
        // The Claude throttle below collapses these into at most one real call.
        scheduleCodex()
        scheduleClaude()
        refreshAll()
        for delay in [4.0, 12.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAll()
            }
        }
    }

    /// `force` (manual refresh, scheduled timer) always fetches Claude; ambient
    /// triggers (menu open, wake retries) are throttled to avoid 429s.
    func refreshAll(force: Bool = false) {
        refreshCodex()
        refreshClaude(force: force)
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
            Task { @MainActor in self?.refreshClaude(force: true) }
        }
    }

    func refreshCodex() {
        Task.detached(priority: .utility) {
            let usage = CodexReader.fetch()
            await MainActor.run {
                self.lastRefresh = Date()
                // A live fetch has no error; a fallback to stale local logs sets
                // one. Right after wake the network is often down, so the first
                // fetch falls back — don't let that overwrite a good live value
                // with an old number (this is why 100% flashed on wake). Adopt
                // the fallback only when we have nothing better to show.
                let isLive = usage.error == nil
                let haveGoodValue = self.codex?.error == nil
                    && (self.codex?.fiveHour != nil || self.codex?.weekly != nil)
                if isLive || !haveGoodValue {
                    self.codex = usage
                    self.notifier.evaluate(usage, settings: self.settings)
                }
            }
        }
    }

    /// Timestamp of the last Claude network fetch, for throttling.
    private var lastClaudeFetch: Date?
    /// The Claude endpoint 429s aggressively, so never call it more than once per
    /// this window from ambient triggers (menu opens, wake retries). The
    /// scheduled timer and the manual refresh button pass force=true to bypass.
    private let claudeThrottle: TimeInterval = 60

    func refreshClaude(force: Bool = false) {
        if !force, let last = lastClaudeFetch,
           Date().timeIntervalSince(last) < claudeThrottle {
            return
        }
        lastClaudeFetch = Date()
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

import Foundation
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published var codex: ProviderUsage?
    @Published var claude: ProviderUsage?
    @Published var lastRefresh: Date?

    // Codex reads local files (cheap). The Claude endpoint rate limits hard, so
    // it is polled far less often.
    private let codexInterval: TimeInterval = 60
    private let claudeInterval: TimeInterval = 300

    private var codexTimer: Timer?
    private var claudeTimer: Timer?

    func start() {
        refreshCodex()
        refreshClaude()
        codexTimer = Timer.scheduledTimer(withTimeInterval: codexInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodex() }
        }
        claudeTimer = Timer.scheduledTimer(withTimeInterval: claudeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClaude() }
        }
    }

    func refreshAll() {
        refreshCodex()
        refreshClaude()
    }

    func refreshCodex() {
        Task.detached(priority: .utility) {
            let usage = CodexReader.latest()
            await MainActor.run {
                self.codex = usage
                self.lastRefresh = Date()
            }
        }
    }

    func refreshClaude() {
        Task.detached(priority: .utility) {
            let usage = ClaudeReader.fetch()
            await MainActor.run {
                self.claude = usage
                self.lastRefresh = Date()
            }
        }
    }

    /// Compact menu-bar title: each provider's most-constrained window percent.
    var barTitle: String {
        func peak(_ u: ProviderUsage?) -> String {
            guard let u else { return "–" }
            let pcts = [u.fiveHour?.usedPercent, u.weekly?.usedPercent].compactMap { $0 }
            guard let m = pcts.max() else { return "–" }
            return formatPercent(m)
        }
        return "Cx \(peak(codex)) · Cl \(peak(claude))"
    }
}

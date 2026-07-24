import SwiftUI
import UsageCore

/// The menu-bar title. Named per provider ("Codex", "Claude") and driven by the
/// user's window / used-vs-remaining preferences. Observes both the data store
/// and settings so it updates immediately when either changes.
struct BarLabelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        Text(title)
    }

    private var title: String {
        var parts: [String] = []
        if settings.showCodex { parts.append(segment("Codex", store.codex)) }
        if settings.showClaude { parts.append(segment("Claude", store.claude)) }
        return parts.isEmpty ? "AI Usage" : parts.joined(separator: "  ·  ")
    }

    private func segment(_ name: String, _ usage: ProviderUsage?) -> String {
        guard let w = preferredWindow(usage, settings.barWindow) else { return "\(name) —" }
        let pct = displayedPercent(usedPercent: w.usedPercent, mode: settings.displayMode)
        return "\(name) \(formatPercent(pct))"
    }
}

import SwiftUI
import UsageCore

/// The menu-bar title. Named per provider ("Codex", "Claude"), colored by
/// severity, and prefixed with a warning icon when any shown window is at/over
/// the warning threshold. Observes both the data store and settings so it
/// updates immediately when either changes.
struct BarLabelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings

    private struct Segment {
        let text: String
        let severity: UsageSeverity
    }

    var body: some View {
        HStack(spacing: 4) {
            if settings.colorMenuBar && segments.contains(where: { $0.severity == .warning }) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            labelText
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        if settings.showCodex { result.append(segment("Codex", store.codex)) }
        if settings.showClaude { result.append(segment("Claude", store.claude)) }
        return result
    }

    private var labelText: Text {
        let segs = segments
        guard !segs.isEmpty else { return Text("AI Usage") }
        var text = Text("")
        for (i, seg) in segs.enumerated() {
            if i > 0 { text = text + Text("  ·  ") }
            var part = Text(seg.text)
            if settings.colorMenuBar, let color = seg.severity.menuBarColor {
                part = part.foregroundColor(color)
            }
            text = text + part
        }
        return text
    }

    private func segment(_ name: String, _ usage: ProviderUsage?) -> Segment {
        guard let w = preferredWindow(usage, settings.barWindow) else {
            return Segment(text: "\(name) —", severity: .normal)
        }
        let pct = displayedPercent(usedPercent: w.usedPercent, mode: settings.displayMode)
        return Segment(text: "\(name) \(formatPercent(pct))",
                       severity: severity(usedPercent: w.usedPercent, settings: settings))
    }
}

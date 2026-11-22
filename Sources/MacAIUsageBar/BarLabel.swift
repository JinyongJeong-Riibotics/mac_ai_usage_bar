import AppKit
import UsageCore

/// Native status-button text keeps its full hit area and standard accessibility.
@MainActor
struct BarLabel {
    let store: UsageStore
    let settings: AppSettings

    private struct Segment {
        let text: String
        let severity: UsageSeverity
    }

    var attributedTitle: NSAttributedString {
        let segments = segments
        let worst: UsageSeverity = segments.contains { $0.severity == .warning } ? .warning
            : segments.contains { $0.severity == .caution } ? .caution : .normal
        let title = NSMutableAttributedString(string: "")
        if settings.colorMenuBar && worst == .warning {
            title.append(part("⚠ ", severity: .warning))
        }
        if settings.isMenuBarCollapsed {
            title.append(part("AI ›", severity: worst))
        } else if segments.isEmpty {
            title.append(part("AI Usage"))
        } else {
            for (index, segment) in segments.enumerated() {
                if index > 0 { title.append(part("  ·  ")) }
                title.append(part(segment.text, severity: segment.severity))
            }
        }
        return title
    }

    private func part(_ text: String, severity: UsageSeverity = .normal) -> NSAttributedString {
        let color: NSColor
        switch settings.colorMenuBar ? severity : .normal {
        case .normal: color = .labelColor
        case .caution: color = .systemOrange
        case .warning: color = .systemRed
        }
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: color,
        ])
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        if settings.showCodex {
            result += settings.enabledCodexAccounts.map {
                segment($0.displayName, store.codexByAccount[$0.id])
            }
        }
        if settings.showClaude {
            result += settings.enabledClaudeAccounts.map {
                segment($0.displayName, store.claudeByAccount[$0.id])
            }
        }
        return result
    }

    private func segment(_ name: String, _ usage: ProviderUsage?) -> Segment {
        guard let window = preferredWindow(usage, settings.barWindow) else {
            return Segment(text: "\(name) —", severity: .normal)
        }
        let percent = displayedPercent(usedPercent: window.usedPercent, mode: settings.displayMode)
        return Segment(text: "\(name) \(formatPercent(percent))",
                       severity: severity(usedPercent: window.usedPercent, settings: settings))
    }
}

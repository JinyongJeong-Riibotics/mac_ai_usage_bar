import SwiftUI

enum UsageSeverity {
    case normal, caution, warning
}

@MainActor
func severity(usedPercent: Double, settings: AppSettings) -> UsageSeverity {
    if usedPercent >= settings.warnThreshold { return .warning }
    if usedPercent >= settings.cautionThreshold { return .caution }
    return .normal
}

extension UsageSeverity {
    /// Menu-bar tint. `nil` means "leave the default label color" so low usage
    /// stays unobtrusive and only caution/warning stand out.
    var menuBarColor: Color? {
        switch self {
        case .normal: return nil
        case .caution: return .orange
        case .warning: return .red
        }
    }

    /// Dropdown color. Always concrete so the progress bars are readable.
    var detailColor: Color {
        switch self {
        case .normal: return .green
        case .caution: return .yellow
        case .warning: return .red
        }
    }
}

import Foundation
import ServiceManagement

enum DisplayMode: String, CaseIterable, Identifiable {
    case used, remaining
    var id: String { rawValue }
    var label: String { self == .used ? "사용량" : "남은 량" }
}

enum BarWindow: String, CaseIterable, Identifiable {
    case fiveHour, weekly
    var id: String { rawValue }
    var label: String { self == .fiveHour ? "5시간" : "주간" }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) } }
    @Published var barWindow: BarWindow { didSet { defaults.set(barWindow.rawValue, forKey: Keys.barWindow) } }
    @Published var showCodex: Bool { didSet { defaults.set(showCodex, forKey: Keys.showCodex) } }
    @Published var showClaude: Bool { didSet { defaults.set(showClaude, forKey: Keys.showClaude) } }
    @Published var launchAtLogin: Bool { didSet { applyLoginItem() } }
    @Published var loginItemError: String?

    // Update intervals in seconds. Codex reads local files so it can be frequent;
    // the Claude endpoint rate-limits hard, so it is clamped to a safe minimum.
    @Published var codexInterval: Double { didSet { defaults.set(codexInterval, forKey: Keys.codexInterval) } }
    @Published var claudeInterval: Double { didSet { defaults.set(claudeInterval, forKey: Keys.claudeInterval) } }

    static let claudeMinInterval: Double = 180

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let displayMode = "displayMode"
        static let barWindow = "barWindow"
        static let showCodex = "showCodex"
        static let showClaude = "showClaude"
        static let codexInterval = "codexInterval"
        static let claudeInterval = "claudeInterval"
    }

    private init() {
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .used
        barWindow = BarWindow(rawValue: defaults.string(forKey: Keys.barWindow) ?? "") ?? .weekly
        showCodex = defaults.object(forKey: Keys.showCodex) as? Bool ?? true
        showClaude = defaults.object(forKey: Keys.showClaude) as? Bool ?? true
        let codex = defaults.object(forKey: Keys.codexInterval) as? Double ?? 60
        let claude = defaults.object(forKey: Keys.claudeInterval) as? Double ?? 300
        codexInterval = max(15, codex)
        claudeInterval = max(AppSettings.claudeMinInterval, claude)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the app as a login item. This only takes effect for a
    /// proper `.app` bundle (built by Xcode); running via `swift run` will report
    /// an error here, which we surface rather than hide.
    private func applyLoginItem() {
        do {
            let service = SMAppService.mainApp
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
    }
}

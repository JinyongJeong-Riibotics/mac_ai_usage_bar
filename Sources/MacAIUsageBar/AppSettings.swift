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

    // Update intervals in seconds. Both providers now hit a network endpoint, so
    // each is clamped to a minimum: Codex's is mild, the Claude endpoint rate
    // limits hard and needs the wider floor.
    @Published var codexInterval: Double { didSet { defaults.set(codexInterval, forKey: Keys.codexInterval) } }
    @Published var claudeInterval: Double { didSet { defaults.set(claudeInterval, forKey: Keys.claudeInterval) } }

    // Warning / notification behavior. `warnThreshold` is a used-percentage; the
    // menu bar goes orange one tier below it and red at/above it.
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) } }
    @Published var colorMenuBar: Bool { didSet { defaults.set(colorMenuBar, forKey: Keys.colorMenuBar) } }
    @Published var warnThreshold: Double { didSet { defaults.set(warnThreshold, forKey: Keys.warnThreshold) } }

    var cautionThreshold: Double { max(0, warnThreshold - 15) }

    static let claudeMinInterval: Double = 180
    static let codexMinInterval: Double = 60

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let displayMode = "displayMode"
        static let barWindow = "barWindow"
        static let showCodex = "showCodex"
        static let showClaude = "showClaude"
        static let codexInterval = "codexInterval"
        static let claudeInterval = "claudeInterval"
        static let notificationsEnabled = "notificationsEnabled"
        static let colorMenuBar = "colorMenuBar"
        static let warnThreshold = "warnThreshold"
    }

    private init() {
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .used
        barWindow = BarWindow(rawValue: defaults.string(forKey: Keys.barWindow) ?? "") ?? .weekly
        showCodex = defaults.object(forKey: Keys.showCodex) as? Bool ?? true
        showClaude = defaults.object(forKey: Keys.showClaude) as? Bool ?? true
        let codex = defaults.object(forKey: Keys.codexInterval) as? Double ?? 60
        let claude = defaults.object(forKey: Keys.claudeInterval) as? Double ?? 300
        codexInterval = max(AppSettings.codexMinInterval, codex)
        claudeInterval = max(AppSettings.claudeMinInterval, claude)
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        colorMenuBar = defaults.object(forKey: Keys.colorMenuBar) as? Bool ?? true
        warnThreshold = defaults.object(forKey: Keys.warnThreshold) as? Double ?? 90
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

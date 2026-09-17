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

struct CodexAccount: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var codexHomePath: String
    var isEnabled: Bool

    static let defaultAccount = CodexAccount(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Codex",
        codexHomePath: "~/.codex",
        isEnabled: true
    )

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Codex" : trimmed
    }

    var loginCommand: String {
        let path = codexHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = ((path.isEmpty ? "~/.codex" : path) as NSString).expandingTildeInPath
        let quoted = "'" + resolved.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "mkdir -p \(quoted) && CODEX_HOME=\(quoted) codex login -c 'cli_auth_credentials_store=\"file\"'"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) } }
    @Published var barWindow: BarWindow { didSet { defaults.set(barWindow.rawValue, forKey: Keys.barWindow) } }
    @Published var showCodex: Bool { didSet { defaults.set(showCodex, forKey: Keys.showCodex) } }
    @Published var showClaude: Bool { didSet { defaults.set(showClaude, forKey: Keys.showClaude) } }
    @Published var codexAccounts: [CodexAccount] { didSet { persistCodexAccounts() } }
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

    // When the Claude token has expired and can't be refreshed from the file,
    // run `claude -p` so Claude Code refreshes its own login. Keeps auth alive
    // without opening a terminal, at the cost of one tiny message per refresh.
    @Published var claudeAutoRefreshViaCLI: Bool { didSet { defaults.set(claudeAutoRefreshViaCLI, forKey: Keys.claudeAutoRefreshViaCLI) } }

    var cautionThreshold: Double { max(0, warnThreshold - 15) }

    static let claudeMinInterval: Double = 180
    static let codexMinInterval: Double = 60

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let displayMode = "displayMode"
        static let barWindow = "barWindow"
        static let showCodex = "showCodex"
        static let showClaude = "showClaude"
        static let codexAccounts = "codexAccounts"
        static let codexInterval = "codexInterval"
        static let claudeInterval = "claudeInterval"
        static let notificationsEnabled = "notificationsEnabled"
        static let colorMenuBar = "colorMenuBar"
        static let warnThreshold = "warnThreshold"
        static let claudeAutoRefreshViaCLI = "claudeAutoRefreshViaCLI"
    }

    private init() {
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .used
        barWindow = BarWindow(rawValue: defaults.string(forKey: Keys.barWindow) ?? "") ?? .weekly
        showCodex = defaults.object(forKey: Keys.showCodex) as? Bool ?? true
        showClaude = defaults.object(forKey: Keys.showClaude) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.codexAccounts),
           let saved = try? JSONDecoder().decode([CodexAccount].self, from: data),
           !saved.isEmpty {
            codexAccounts = saved
        } else {
            codexAccounts = [.defaultAccount]
        }
        let codex = defaults.object(forKey: Keys.codexInterval) as? Double ?? 60
        let claude = defaults.object(forKey: Keys.claudeInterval) as? Double ?? 300
        codexInterval = max(AppSettings.codexMinInterval, codex)
        claudeInterval = max(AppSettings.claudeMinInterval, claude)
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        colorMenuBar = defaults.object(forKey: Keys.colorMenuBar) as? Bool ?? true
        warnThreshold = defaults.object(forKey: Keys.warnThreshold) as? Double ?? 90
        claudeAutoRefreshViaCLI = defaults.object(forKey: Keys.claudeAutoRefreshViaCLI) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var enabledCodexAccounts: [CodexAccount] {
        codexAccounts.filter(\.isEnabled)
    }

    func addCodexAccount() {
        var number = 2
        let existingPaths = Set(codexAccounts.map(\.codexHomePath))
        while existingPaths.contains("~/.codex-accounts/account-\(number)") { number += 1 }
        codexAccounts.append(CodexAccount(
            id: UUID(),
            name: "Codex \(number)",
            codexHomePath: "~/.codex-accounts/account-\(number)",
            isEnabled: true
        ))
    }

    func removeCodexAccount(id: UUID) {
        guard codexAccounts.count > 1 else { return }
        codexAccounts.removeAll { $0.id == id }
    }

    private func persistCodexAccounts() {
        guard let data = try? JSONEncoder().encode(codexAccounts) else { return }
        defaults.set(data, forKey: Keys.codexAccounts)
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

import Foundation
import UserNotifications
import UsageCore

/// Posts a macOS notification when a window crosses the warning threshold.
/// Notifications require a real bundle identifier, so this is a no-op under
/// `swift run`; it only fires from the packaged `.app`.
@MainActor
final class UsageNotifier {
    private var notifiedKeys = Set<String>()
    private var authorized = false
    private var didRequest = false

    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthIfNeeded() {
        guard available, !didRequest else { return }
        didRequest = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in self.authorized = granted }
            }
    }

    func evaluate(_ usage: ProviderUsage, settings: AppSettings) {
        guard available, settings.notificationsEnabled else { return }
        for w in [usage.fiveHour, usage.weekly].compactMap({ $0 }) {
            let key = "\(usage.provider.rawValue)|\(w.window.label)|\(Int(w.resetsAt.timeIntervalSince1970))"
            if w.usedPercent >= settings.warnThreshold {
                if notifiedKeys.insert(key).inserted {
                    post(provider: usage.provider, window: w)
                }
            } else if w.usedPercent < settings.cautionThreshold {
                // Hysteresis: only re-arm once it falls clearly back down, so a
                // value hovering at the threshold doesn't spam notifications.
                notifiedKeys.remove(key)
            }
        }
    }

    private func post(provider: Provider, window: RateWindow) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.rawValue) 사용량 경고"
        content.body = "\(window.window.label) 사용률 \(formatPercent(window.usedPercent)) · 리셋 \(formatReset(window.timeUntilReset))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

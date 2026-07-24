import SwiftUI
import UsageCore

/// App version string from the bundle (`CFBundleShortVersionString`), e.g.
/// "1.2.1". Falls back to "dev" when run outside a bundle (`swift run`).
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if settings.showCodex {
                ProviderSection(title: "Codex", systemImage: "chevron.left.forwardslash.chevron.right",
                                usage: store.codex, settings: settings)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            if settings.showCodex && settings.showClaude { Divider().padding(.horizontal, 14) }
            if settings.showClaude {
                ProviderSection(title: "Claude", systemImage: "sparkle",
                                usage: store.claude, settings: settings,
                                notice: store.claudeNotice)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Divider()
            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(.secondary)
            Text("AI Usage")
                .font(.headline)
            Text("v\(appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(settings.displayMode.label)
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let t = store.lastRefresh {
                Label(t.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.refreshAll() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("지금 새로고침")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("설정")

            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("종료")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ProviderSection: View {
    let title: String
    let systemImage: String
    let usage: ProviderUsage?
    @ObservedObject var settings: AppSettings
    var notice: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.semibold))
            }

            if let usage, usage.fiveHour == nil && usage.weekly == nil {
                Text(usage.error ?? "데이터 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                WindowRow(label: "5시간", window: usage?.fiveHour, settings: settings)
                WindowRow(label: "주간", window: usage?.weekly, settings: settings)
            }

            // Codex numbers come from this machine's local session logs, so they
            // are only as fresh as the last local Codex run. Say so when the
            // sample is stale, otherwise an old reading looks like a live one.
            if let usage, let staleness = staleSampleNotice(usage) {
                Text(staleness)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Codex reads local rollout logs, so a machine that has not run Codex in a
/// while keeps reporting the last percentage it saw. Surface the sample age
/// once it is old enough to mislead (Claude is fetched live, so it is exempt).
func staleSampleNotice(_ usage: ProviderUsage, now: Date = Date()) -> String? {
    guard usage.provider == .codex else { return nil }
    guard usage.fiveHour != nil || usage.weekly != nil else { return nil }
    let age = now.timeIntervalSince(usage.sampledAt)
    guard age > 3600 else { return nil }
    return "이 PC의 Codex 로그 기준 · \(formatReset(age)) 전 기록"
}

private struct WindowRow: View {
    let label: String
    let window: RateWindow?
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                if let w = window {
                    Text(formatPercent(displayedPercent(usedPercent: w.usedPercent, mode: settings.displayMode)))
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(color(forUsed: w.usedPercent))
                    Spacer()
                    Text("리셋 \(formatReset(w.timeUntilReset))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if let w = window {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(color(forUsed: w.usedPercent))
                            .frame(width: geo.size.width * min(w.usedPercent, 100) / 100)
                    }
                }
                .frame(height: 5)
            }
        }
    }

    // Color always reflects how *used up* the window is, regardless of whether
    // we display the used or the remaining number — red always means danger.
    private func color(forUsed pct: Double) -> Color {
        severity(usedPercent: pct, settings: settings).detailColor
    }
}

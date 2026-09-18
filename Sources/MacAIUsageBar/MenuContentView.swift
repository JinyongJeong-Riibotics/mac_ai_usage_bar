import SwiftUI
import UsageCore

/// App version string from the bundle (`CFBundleShortVersionString`), e.g.
/// "1.2.1". Falls back to "dev" when run outside a bundle (`swift run`).
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings

    private var codexAccounts: [CodexAccount] {
        settings.showCodex ? settings.enabledCodexAccounts : []
    }

    private var claudeAccounts: [ClaudeAccount] {
        settings.showClaude ? settings.enabledClaudeAccounts : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ForEach(codexAccounts) { account in
                ProviderSection(title: account.displayName,
                                systemImage: "chevron.left.forwardslash.chevron.right",
                                usage: store.codexByAccount[account.id],
                                settings: settings,
                                notice: store.codexNotices[account.id])
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                if account.id != codexAccounts.last?.id {
                    Divider().padding(.horizontal, 14)
                }
            }
            if !codexAccounts.isEmpty && !claudeAccounts.isEmpty {
                Divider().padding(.horizontal, 14)
            }
            ForEach(claudeAccounts) { account in
                ProviderSection(title: account.displayName, systemImage: "sparkle",
                                usage: store.claudeByAccount[account.id], settings: settings,
                                notice: store.claudeNotices[account.id])
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                if account.id != claudeAccounts.last?.id {
                    Divider().padding(.horizontal, 14)
                }
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
            Button { store.refreshAll(force: true) } label: {
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
                if let count = usage?.rateLimitResetCredits {
                    HStack {
                        Label("리셋 티켓", systemImage: "ticket")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(count)개")
                            .font(.callout.monospacedDigit().weight(.medium))
                    }
                    .font(.caption)
                }
            }

            if let notice, notice != usage?.error {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
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

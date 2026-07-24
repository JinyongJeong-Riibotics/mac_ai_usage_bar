import SwiftUI
import UsageCore

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderSection(title: "Codex", usage: store.codex)
            Divider()
            ProviderSection(title: "Claude", usage: store.claude)
            Divider()
            HStack {
                if let t = store.lastRefresh {
                    Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { store.refreshAll() }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

private struct ProviderSection: View {
    let title: String
    let usage: ProviderUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)

            if let usage, usage.fiveHour == nil && usage.weekly == nil {
                Text(usage.error ?? "no data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                WindowRow(label: "5h", window: usage?.fiveHour)
                WindowRow(label: "Weekly", window: usage?.weekly)
            }
        }
    }
}

private struct WindowRow: View {
    let label: String
    let window: RateWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.subheadline).frame(width: 54, alignment: .leading)
                if let w = window {
                    Text(formatPercent(w.usedPercent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(color(for: w.usedPercent))
                    Spacer()
                    Text("resets in \(formatReset(w.timeUntilReset))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if let w = window {
                ProgressView(value: min(w.usedPercent, 100), total: 100)
                    .tint(color(for: w.usedPercent))
            }
        }
    }

    private func color(for pct: Double) -> Color {
        switch pct {
        case ..<50: return .green
        case ..<80: return .yellow
        default: return .red
        }
    }
}

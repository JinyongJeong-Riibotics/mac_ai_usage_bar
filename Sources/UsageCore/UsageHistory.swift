import Foundation

/// One successful provider sample kept for the seven-day history chart.
/// Percentages are always "used" values, independent of the UI's
/// used/remaining display preference.
public struct UsageHistorySample: Codable, Hashable, Sendable {
    public let sampledAt: Date
    public let fiveHourUsedPercent: Double?
    public let weeklyUsedPercent: Double?

    public init(sampledAt: Date,
                fiveHourUsedPercent: Double?,
                weeklyUsedPercent: Double?) {
        self.sampledAt = sampledAt
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.weeklyUsedPercent = weeklyUsedPercent
    }
}

/// File-backed history for every provider/account pair. The archive contains
/// usage percentages only — never account paths, tokens, or credentials.
public final class UsageHistoryStorage {
    public static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60

    private struct Key: Hashable {
        let provider: Provider
        let accountID: UUID
    }

    private struct Series: Codable {
        let provider: Provider
        let accountID: UUID
        var samples: [UsageHistorySample]
    }

    private struct Archive: Codable {
        let version: Int
        var series: [Series]
    }

    public let fileURL: URL
    public let retention: TimeInterval

    private var samplesByKey: [Key: [UsageHistorySample]] = [:]
    private let fileManager: FileManager

    public init(fileURL: URL = UsageHistoryStorage.defaultFileURL(),
                retention: TimeInterval = UsageHistoryStorage.defaultRetention,
                now: Date = Date(),
                fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.retention = retention
        self.fileManager = fileManager
        load()
        if prune(now: now) {
            try? persist()
        }
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent("io.riibotics.MacAIUsageBar", isDirectory: true)
            .appendingPathComponent("usage-history.json")
    }

    /// Adds a successful sample, removes everything older than the retention
    /// window, and atomically updates the archive. Rapid duplicate refreshes
    /// within 30 seconds replace the previous point instead of bloating it.
    @discardableResult
    public func record(_ usage: ProviderUsage,
                       accountID: UUID,
                       now: Date = Date()) throws -> Bool {
        guard usage.fiveHour != nil || usage.weekly != nil else { return false }

        _ = prune(now: now)
        let cutoff = now.addingTimeInterval(-retention)
        guard usage.sampledAt >= cutoff else {
            try persist()
            return false
        }

        let key = Key(provider: usage.provider, accountID: accountID)
        let sample = UsageHistorySample(
            sampledAt: usage.sampledAt,
            fiveHourUsedPercent: usage.fiveHour.map { Self.clamped($0.usedPercent) },
            weeklyUsedPercent: usage.weekly.map { Self.clamped($0.usedPercent) }
        )
        var samples = samplesByKey[key, default: []]
        if let last = samples.last,
           abs(last.sampledAt.timeIntervalSince(sample.sampledAt)) < 30 {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
            samples.sort { $0.sampledAt < $1.sampledAt }
        }
        samplesByKey[key] = samples
        try persist()
        return true
    }

    /// Returns only samples in the current seven-day window. Calling this also
    /// performs maintenance so stale records are deleted even before the next
    /// provider refresh.
    public func samples(provider: Provider,
                        accountID: UUID,
                        now: Date = Date()) -> [UsageHistorySample] {
        if prune(now: now) {
            try? persist()
        }
        return samplesByKey[Key(provider: provider, accountID: accountID)] ?? []
    }

    @discardableResult
    private func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-retention)
        var changed = false
        for key in Array(samplesByKey.keys) {
            let current = samplesByKey[key] ?? []
            let retained = current.filter { $0.sampledAt >= cutoff }
            if retained.count != current.count { changed = true }
            if retained.isEmpty {
                samplesByKey.removeValue(forKey: key)
            } else {
                samplesByKey[key] = retained
            }
        }
        return changed
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let archive = try? decoder.decode(Archive.self, from: data),
              archive.version == 1 else { return }
        for series in archive.series {
            let key = Key(provider: series.provider, accountID: series.accountID)
            samplesByKey[key, default: []].append(contentsOf: series.samples)
        }
        for key in Array(samplesByKey.keys) {
            samplesByKey[key]?.sort { $0.sampledAt < $1.sampledAt }
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true)
        let series = samplesByKey.map { key, samples in
            Series(provider: key.provider, accountID: key.accountID, samples: samples)
        }.sorted {
            if $0.provider.rawValue != $1.provider.rawValue {
                return $0.provider.rawValue < $1.provider.rawValue
            }
            return $0.accountID.uuidString < $1.accountID.uuidString
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(Archive(version: 1, series: series))
        try data.write(to: fileURL, options: .atomic)
    }

    private static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

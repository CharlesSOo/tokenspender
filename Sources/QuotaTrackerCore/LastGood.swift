import Foundation

/// Offline resilience: rows that fail transiently, or whose Claude login could not be renewed, keep
/// their last good usage, marked stale, and the
/// last good rows persist across launches. Only usage numbers, labels, reset times and row ids are kept.
public enum LastGood {
    public static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuotaTracker/last-snapshot.json")

    static func isGood(_ row: RowUsage) -> Bool { row.isConfigured && row.error == nil && !row.windows.isEmpty }

    /// A failure that last good numbers may stand in for: transient, or a login failure carrying a hint.
    static func isRecoverable(_ row: RowUsage) -> Bool { row.error != nil && (row.isTransient || row.hint != nil) }

    /// `fresh` with each recoverable failure replaced by the matching good row from `previous`, marked
    /// stale and carrying the failure's hint. Codex matches by identity (or slot when the failure carries
    /// none); Claude by account id, or by profile when the failure happened before the account was verified.
    public static func merge(fresh: UsageSnapshot, previous: UsageSnapshot) -> UsageSnapshot {
        func keep(_ new: RowUsage, _ old: RowUsage) -> RowUsage {
            guard isRecoverable(new), isGood(old),
                  new.identity == nil || old.identity == nil || new.identity == old.identity else { return new }
            var row = old
            row.isStale = true
            row.hint = new.hint
            return row
        }
        var merged = fresh
        merged.codex = keep(fresh.codex, previous.codex)
        for index in merged.claude.indices {
            let account = merged.claude[index]
            guard isRecoverable(account.usage),
                  let old = previous.claude.first(where: { old in
                      old.id != nil && (account.id.map { $0 == old.id } ?? (old.profile == account.profile)) && isGood(old.usage)
                  }) else { continue }
            // Never show the same verified account twice.
            if merged.claude.contains(where: { $0.id == old.id && isGood($0.usage) }) { continue }
            merged.claude[index] = ClaudeAccount(profile: old.profile, email: old.email, usage: keep(account.usage, old.usage), id: old.id, plan: old.plan)
        }
        return merged
    }

    /// Good rows only (fresh or stale); nil when there are none.
    public static func persistable(_ snapshot: UsageSnapshot) -> UsageSnapshot? {
        let claude = snapshot.claude.filter { $0.id != nil && isGood($0.usage) }
        let codex = isGood(snapshot.codex) ? snapshot.codex : nil
        if codex == nil && claude.isEmpty { return nil }
        return UsageSnapshot(codex: codex ?? RowUsage(), claude: claude)
    }

    public static func save(_ snapshot: UsageSnapshot, to url: URL = defaultURL) throws {
        guard let good = persistable(snapshot) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(good).write(to: url, options: .atomic)
    }

    /// The saved rows, all stale; nil when the file is missing or unreadable.
    public static func load(from url: URL = defaultURL) -> UsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), var snapshot = try? decoder.decode(UsageSnapshot.self, from: data) else { return nil }
        if isGood(snapshot.codex) { snapshot.codex.isStale = true }
        for index in snapshot.claude.indices { snapshot.claude[index].usage.isStale = true }
        return snapshot
    }

    /// Stale windows whose reset has passed read as reset: 100% left, no countdown.
    public static func resettingPast(_ snapshot: UsageSnapshot, now: Date) -> UsageSnapshot {
        func reset(_ row: RowUsage) -> RowUsage {
            guard row.isStale else { return row }
            var row = row
            row.windows = row.windows.map { w in
                guard let at = w.resetsAt, at <= now else { return w }
                return UsageWindow(label: w.label, percentLeft: 100, resetsAt: nil)
            }
            return row
        }
        var copy = snapshot
        copy.codex = reset(copy.codex)
        for index in copy.claude.indices { copy.claude[index].usage = reset(copy.claude[index].usage) }
        return copy
    }
}

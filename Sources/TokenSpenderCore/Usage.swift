import Foundation

public struct UsageWindow: Equatable, Sendable {
    public let label: String
    public let percentLeft: Double
    public let resetsAt: Date?

    public init(label: String, percentLeft: Double, resetsAt: Date?) {
        self.label = label
        self.percentLeft = percentLeft
        self.resetsAt = resetsAt
    }
}

public struct RowUsage: Equatable, Sendable {
    public var windows: [UsageWindow] = []
    public var error: String?
    /// False when the provider has no credentials at all (as opposed to expired ones); such rows are hidden.
    public var isConfigured = true
    /// Source observation time, not the time a cached response was read.
    public var observedAt: Date?
    public var identity: String?

    /// The window with the least left.
    public var constraining: UsageWindow? { windows.min { $0.percentLeft < $1.percentLeft } }

    public init(windows: [UsageWindow] = [], error: String? = nil, isConfigured: Bool = true, observedAt: Date? = nil) {
        self.windows = windows
        self.error = error
        self.isConfigured = isConfigured
        self.observedAt = observedAt
    }

    public static func failure(_ message: String) -> RowUsage { RowUsage(error: message) }
    public static let notConfigured = RowUsage(error: "not configured", isConfigured: false)
}

/// One cswap slot. Rows are ordered by `slot`; `email` is the display name.
public struct ClaudeAccount: Equatable, Sendable {
    public let slot: Int
    public let email: String
    public var usage: RowUsage

    public init(slot: Int, email: String, usage: RowUsage) {
        self.slot = slot
        self.email = email
        self.usage = usage
    }

    /// Stable key for sample history and UI identity.
    public var id: String { "claude/\(slot)/\(email)" }
}

/// One fetch of every provider. Claude accounts come from cswap and may be empty.
public struct UsageSnapshot: Equatable, Sendable {
    public var codex: RowUsage
    public var claude: [ClaudeAccount]
    public var kimi: RowUsage

    public init(codex: RowUsage = RowUsage(), claude: [ClaudeAccount] = [], kimi: RowUsage = RowUsage()) {
        self.codex = codex
        self.claude = claude
        self.kimi = kimi
    }

    /// Claude usages with credentials (hidden slots excluded).
    public var claudeUsages: [RowUsage] { claude.map(\.usage).filter(\.isConfigured) }
}

/// What the menu-bar label shows. Raw values are persisted in UserDefaults; case order is menu order.
public enum DisplayMode: Int, CaseIterable, Sendable {
    case availableNow = 5, lowest = 0, claudePool = 1, codexPool = 6

    public var title: String {
        switch self {
        case .availableNow: "Available now"
        case .lowest: "Lowest account"
        case .claudePool: "Claude pool"
        case .codexPool: "Codex pool"
        }
    }

}

/// Estimated equal-account mean of limiting quota percentages, NOT remaining token capacity.
public enum AvailableNow {
    public static func share(rows: [RowUsage]) -> Double? { Pool.share(label: nil, accounts: rows) }
}

public enum Pool {
    public static func share(label: String?, accounts: [RowUsage]) -> Double? {
        let values = accounts.filter { $0.isConfigured && $0.error == nil }.compactMap { account in
            (label.map { l in account.windows.filter { $0.label == l }.min { $0.percentLeft < $1.percentLeft } } ?? account.constraining)?.percentLeft
        }.filter(\.isFinite)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public static func summary(accounts: [RowUsage]) -> String? {
        let parts = ["5H", "WK"].compactMap { (label: String) in share(label: label, accounts: accounts).map { "\(label) \(Format.percent($0))" } }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum MenuLabel {
    public static func text(mode: DisplayMode, snapshot: UsageSnapshot) -> String {
        let claude = snapshot.claudeUsages
        let all = ([snapshot.codex, snapshot.kimi] + claude).filter { $0.isConfigured && $0.error == nil }
        switch mode {
        case .availableNow: return Format.percent(AvailableNow.share(rows: all))
        case .lowest: return Format.percent(all.compactMap { $0.constraining?.percentLeft }.min())
        case .claudePool: return Format.percent(Pool.share(label: nil, accounts: claude))
        case .codexPool: return Format.percent(Pool.share(label: nil, accounts: [snapshot.codex]))
        }
    }
}

public enum Format {
    public static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// "6d 22h", "4h 37m", "12m"; nil for non-positive spans.
    public static func duration(_ seconds: TimeInterval) -> String? {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 0 { return nil }
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

/// One usage observation for a window; the app keeps a short in-memory ring of these per account+window.
public struct UsageSample: Equatable, Sendable {
    public let at: Date
    public let percentLeft: Double
    public init(at: Date, percentLeft: Double) {
        self.at = at
        self.percentLeft = percentLeft
    }
}

/// Bounded in-memory history; keys include account identity, window index and reset boundary.
public struct SampleHistory: Sendable {
    public static let maxAge: TimeInterval = 24 * 3600
    public static let maxCount = 288
    private var values: [String: [UsageSample]] = [:]
    public init() {}
    public func samples(_ key: String) -> [UsageSample] { values[key] ?? [] }
    public mutating func retain(keys: Set<String>, now: Date) {
        values = values.filter { keys.contains($0.key) }
        for key in values.keys { values[key]?.removeAll { now.timeIntervalSince($0.at) > Self.maxAge } }
    }
    public mutating func append(_ key: String, _ sample: UsageSample) {
        guard sample.percentLeft.isFinite else { return }
        var run = values[key] ?? []
        if let last = run.last {
            guard sample.at > last.at else { return } // cached/source timestamps never advance history
            if sample.percentLeft > last.percentLeft { run.removeAll() }
        }
        run.append(sample)
        run.removeAll { sample.at.timeIntervalSince($0.at) > Self.maxAge }
        if run.count > Self.maxCount { run.removeFirst(run.count - Self.maxCount) }
        values[key] = run
    }
}

public enum BurnRate {
    public static let minSamples = 3
    public static let minSpan: TimeInterval = 15 * 60

    /// Least-squares consumption rate over distinct source-timestamp observations.
    public static func eta(samples: [UsageSample]) -> TimeInterval? {
        guard samples.count >= minSamples else { return nil }
        var run: [UsageSample] = []
        for sample in samples {
            if let last = run.last {
                guard sample.at > last.at else { continue }
                if sample.percentLeft > last.percentLeft { run.removeAll() }
            }
            run.append(sample)
        }
        guard let first = run.first, let last = run.last,
              Set(run.map(\.percentLeft)).count >= minSamples,
              last.at.timeIntervalSince(first.at) >= minSpan,
              last.percentLeft > 0, last.percentLeft < first.percentLeft else { return nil }
        let xs = run.map { $0.at.timeIntervalSince(first.at) }
        let ys = run.map(\.percentLeft)
        let meanX = xs.reduce(0, +) / Double(run.count)
        let meanY = ys.reduce(0, +) / Double(run.count)
        let covariance = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let variance = xs.reduce(0.0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard variance > 0 else { return nil }
        let rate = -covariance / variance
        guard rate > 0 else { return nil }
        return last.percentLeft / rate
    }

    /// "5h burnt in ~1h 6m" / "wk burnt in ~2d 4h" for the window that burns soonest, only if that
    /// happens before its reset; otherwise nil.
    public static func label(usage: RowUsage, history: (Int) -> [UsageSample], now: Date) -> String? {
        let etas = usage.windows.enumerated().compactMap { index, window -> (String, TimeInterval)? in
            let samples = history(index)
            guard let last = samples.last, now.timeIntervalSince(last.at) <= 15 * 60,
                  let eta = eta(samples: samples) else { return nil }
            if let reset = window.resetsAt, eta >= reset.timeIntervalSince(now) { return nil }
            return (window.label.lowercased(), eta)
        }
        guard let soonest = etas.min(by: { $0.1 < $1.1 }), let text = Format.duration((soonest.1 / 300).rounded(.up) * 300) else { return nil }
        return "\(soonest.0) burnt in ~\(text)"
    }
}

public enum Parse {
    private struct CSList: Decodable {
        struct Window: Decodable {
            let pct: Double?
            let resetsAt: String?
        }
        struct Usage: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?
        }
        struct Account: Decodable {
            let number: Int?
            let email: String
            let usageStatus: String?
            let usageFetchedAt: String?
            let usage: Usage?
        }
        let accounts: [Account]
    }


    /// Accounts ordered by slot number; slots without a number are skipped. Nil if the JSON is unreadable.
    public static func cswap(_ data: Data) -> [ClaudeAccount]? {
        guard let list = try? JSONDecoder().decode(CSList.self, from: data) else { return nil }
        return list.accounts
            .compactMap { a in a.number.map { ClaudeAccount(slot: $0, email: a.email, usage: cswapUsage(a)) } }
            .sorted { $0.slot < $1.slot }
    }

    private static func cswapUsage(_ account: CSList.Account) -> RowUsage {
        if let status = account.usageStatus, status != "ok" { return cswapStatus(status) }
        guard let usage = account.usage else { return cswapStatus(account.usageStatus ?? "unavailable") }
        let windows = [("5H", usage.fiveHour), ("WK", usage.sevenDay)].compactMap { label, w -> UsageWindow? in
            guard let w, let pct = w.pct else { return nil }
            return UsageWindow(label: label, percentLeft: left(pct), resetsAt: w.resetsAt.flatMap(date))
        }
        return windows.isEmpty ? .failure("No usage windows") : RowUsage(windows: windows, observedAt: account.usageFetchedAt.flatMap(date))
    }

    /// cswap `usageStatus` other than `ok`, mapped to the same quiet states the other providers use:
    /// `token_expired`/`relogin_required` → "expired", `no_credentials` → hidden, anything else → "unavailable".
    static func cswapStatus(_ status: String) -> RowUsage {
        switch status {
        case "token_expired", "relogin_required": return .failure("expired")
        case "no_credentials": return .notConfigured
        default: return .failure("unavailable")
        }
    }

    // MARK: helpers

    static func left(_ used: Double) -> Double { min(100, max(0, 100 - used)) }

    /// ISO 8601 with optional fractional seconds (cswap emits microseconds and `+00:00`).
    static func date(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        // Trim fractional seconds to milliseconds so the formatter accepts them.
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: trimmed)
    }

    /// CodexBar wording for "no credentials at all"; expired/401 messages are checked first and never match.
    static func isNotConfigured(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("expired") || lower.contains("401") || lower.contains("unauthorized") { return false }
        return ["not configured", "not logged in", "not found", "no credentials"].contains { lower.contains($0) }
    }

    /// One calm line instead of raw HTTP bodies.
    static func quiet(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("expired") || lower.contains("401") || lower.contains("unauthorized") {
            return "expired"
        }
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}

public enum ResetFormat {
    /// "3h 57m" until reset; "resetting" once due; nil when unknown.
    public static func countdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        return Format.duration(date.timeIntervalSince(now)) ?? "resetting"
    }

    /// "5h resets 3h 48m · wk resets 6d 21h"; a lone window reads "resets 5d 20h". Nil if no reset is known.
    public static func line(for windows: [UsageWindow], now: Date = Date()) -> String? {
        let parts = windows.compactMap { w in countdown(to: w.resetsAt, now: now).map { (w.label.lowercased(), "resets \($0)") } }
        if parts.isEmpty { return nil }
        if parts.count == 1 { return parts[0].1 }
        return parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}

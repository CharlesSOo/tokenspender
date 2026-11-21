import Foundation

public struct UsageWindow: Equatable, Sendable, Codable {
    public let label: String
    public let percentLeft: Double
    public let resetsAt: Date?

    public init(label: String, percentLeft: Double, resetsAt: Date?) {
        self.label = label
        self.percentLeft = percentLeft
        self.resetsAt = resetsAt
    }
}

public struct RowUsage: Equatable, Sendable, Codable {
    public var windows: [UsageWindow] = []
    public var error: String?
    /// The error is a connectivity/server hiccup (offline, timeout, 5xx, 429); last good data may stand in.
    /// Kept on a stale row: it is stale because the network failed (the footer then says OFFLINE).
    public var isTransient = false
    /// Last good data shown in place of a failure; `observedAt` is when it was fetched.
    public var isStale = false
    /// False when the provider has no credentials at all (as opposed to expired ones); such rows are hidden.
    public var isConfigured = true
    /// Source observation time, not the time a cached response was read.
    public var observedAt: Date?
    public var identity: String?
    /// What the user must do, e.g. "signed out · run claude in ~/.claude"; set only once renewal keeps failing.
    public var hint: String?

    /// The window with the least left.
    public var constraining: UsageWindow? { windows.min { $0.percentLeft < $1.percentLeft } }

    public init(windows: [UsageWindow] = [], error: String? = nil, isConfigured: Bool = true, observedAt: Date? = nil) {
        self.windows = windows
        self.error = error
        self.isConfigured = isConfigured
        self.observedAt = observedAt
    }

    public static func failure(_ message: String, transient: Bool = false) -> RowUsage {
        var row = RowUsage(error: message)
        row.isTransient = transient
        return row
    }
    public static let notConfigured = RowUsage(error: "not configured", isConfigured: false)
}

/// One Claude Code config profile's account. `profile` is the config dir label (e.g. "~/.claude-me");
/// `email` is only a display name.
public struct ClaudeAccount: Equatable, Sendable, Codable {
    public let profile: String
    public let email: String
    public var usage: RowUsage
    /// Account UUID + organization UUID from the native OAuth profile; nil if unverified.
    public let id: String?
    /// Current plan from the OAuth profile (e.g. "Ultra"), fetched every poll.
    public var plan: String?

    public init(profile: String, email: String, usage: RowUsage, id: String? = nil, plan: String? = nil) {
        self.profile = profile
        self.email = email
        self.usage = usage
        self.id = id
        self.plan = plan
    }

    /// Row title: "you@example.com · Ultra".
    public var title: String { plan.map { "\(email) · \($0)" } ?? email }

    /// Line under the row, never an "expired" error: the signed-out hint once renewal keeps failing, or
    /// straight away when an expired login has no last good numbers to show. Nil while renewing silently.
    public var hint: String? {
        usage.hint ?? (usage.error == NativeClaude.Failure.expired.rawValue ? NativeClaude.signedOutHint(profile) : nil)
    }
}

/// One fetch of every provider. Claude has one row per Claude Code config profile.
public struct UsageSnapshot: Equatable, Sendable, Codable {
    public var codex: RowUsage
    public var claude: [ClaudeAccount]

    public init(codex: RowUsage = RowUsage(), claude: [ClaudeAccount] = []) {
        self.codex = codex
        self.claude = claude
    }
}

/// What the menu-bar label shows. Raw values are persisted in UserDefaults; case order is menu order.
/// Retired modes (0 lowest, 5 available now) fall back to the Claude pool.
public enum DisplayMode: Int, CaseIterable, Sendable {
    case claudePool = 1, codexPool = 6

    public var title: String {
        switch self {
        case .claudePool: "Claude pool"
        case .codexPool: "Codex"
        }
    }
}

/// Weekly capacity of a Claude plan relative to Pro, keyed by the profile's `plan_display_name`.
/// shortcut: hand-kept table (Pro 1, Max 5, Ultra 10) from Anthropic's published plan multiples; update it
/// when Anthropic adds, renames or re-sizes a plan. Unknown plans weigh 1.
public enum PlanWeight {
    static let table: [String: Int] = ["pro": 1, "max": 5, "ultra": 10]

    /// Nil when the plan is absent or not in the table.
    public static func of(_ plan: String?) -> Int? {
        plan.flatMap { table[$0.trimmingCharacters(in: .whitespaces).lowercased()] }
    }
}

/// All Claude accounts as one plan-weighted pool. Lines are weighted means of percent left, NOT token
/// balances. Accounts with no numbers (errors, still loading) are left out; stale last-good rows count.
public struct ClaudePool: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let label: String
        public let percentLeft: Double
    }

    /// Σ plan weights of pooled accounts, in units of Pro.
    public let size: Int
    /// "NOW", "WK", then one line per model-scoped weekly cap (e.g. "FABLE"); lines with no data are omitted.
    public let lines: [Line]

    /// Per account min(5H, WK) left, a missing 5H window counting as 100% (that plan has no 5-hour limit).
    public var now: Double? { lines.first { $0.label == "NOW" }?.percentLeft }

    public init(accounts: [ClaudeAccount]) {
        let pooled = accounts.filter { $0.usage.isConfigured && $0.usage.error == nil && !$0.usage.windows.isEmpty }
        let weights = pooled.map { Double(PlanWeight.of($0.plan) ?? 1) }
        size = Int(weights.reduce(0, +))

        func left(_ usage: RowUsage, _ label: String) -> Double? {
            usage.windows.filter { $0.label == label && $0.percentLeft.isFinite }.map(\.percentLeft).min()
        }
        /// Weighted mean over accounts that have a value; accounts without one are excluded.
        func mean(_ value: (RowUsage) -> Double?) -> Double? {
            let pairs = zip(weights, pooled).compactMap { weight, account in value(account.usage).map { (weight, $0) } }
            let total = pairs.reduce(0) { $0 + $1.0 }
            return total > 0 ? pairs.reduce(0) { $0 + $1.0 * $1.1 } / total : nil
        }

        var labels: [String] = []
        for window in pooled.flatMap(\.usage.windows) where !["5H", "WK"].contains(window.label) && !labels.contains(window.label) {
            labels.append(window.label)
        }
        let now = mean { usage in
            let week = left(usage, "WK"), five = left(usage, "5H")
            if week == nil && five == nil { return nil }
            return min(five ?? 100, week ?? 100)
        }
        let candidates: [(String, Double?)] = [("NOW", now), ("WK", mean { left($0, "WK") })] + labels.map { label in (label, mean { left($0, label) }) }
        lines = candidates.compactMap { label, value in value.map { Line(label: label, percentLeft: $0) } }
    }
}

public enum MenuLabel {
    public static func text(mode: DisplayMode, snapshot: UsageSnapshot) -> String {
        switch mode {
        case .claudePool: return Format.percent(ClaudePool(accounts: snapshot.claude).now)
        case .codexPool:
            let codex = snapshot.codex
            return Format.percent(codex.isConfigured && codex.error == nil ? codex.constraining?.percentLeft : nil)
        }
    }
}

public enum Footer {
    /// "OFFLINE · UPDATED 3H AGO" for the oldest row kept stale by a network failure. Rows stale for
    /// other reasons (a login being renewed) are only dimmed, so nil: the footer shows the normal update time.
    public static func offline(_ rows: [RowUsage], now: Date) -> String? {
        let stale = rows.filter { $0.isConfigured && $0.isStale && $0.isTransient }.compactMap(\.observedAt)
        guard let at = stale.min() else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(at) / 60))
        let ago = minutes < 1 ? "JUST NOW" : minutes < 60 ? "\(minutes)M AGO" : minutes < 1440 ? "\(minutes / 60)H AGO" : "\(minutes / 1440)D AGO"
        return "OFFLINE · UPDATED \(ago)"
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
    // MARK: helpers

    static func left(_ used: Double) -> Double { min(100, max(0, 100 - used)) }

    /// ISO 8601 with optional fractional seconds (microseconds and `+00:00` accepted).
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
            return "signed out"
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
    /// Windows resetting together (a model cap sharing the weekly reset) are listed once.
    public static func line(for windows: [UsageWindow], now: Date = Date()) -> String? {
        var seen: [Date] = []
        let unique = windows.filter { w in
            guard let at = w.resetsAt else { return true }
            if seen.contains(where: { abs($0.timeIntervalSince(at)) < 60 }) { return false }
            seen.append(at)
            return true
        }
        let parts = unique.compactMap { w in countdown(to: w.resetsAt, now: now).map { (w.label.lowercased(), "resets \($0)") } }
        if parts.isEmpty { return nil }
        if parts.count == 1 { return parts[0].1 }
        return parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}

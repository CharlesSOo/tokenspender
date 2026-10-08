import Foundation

/// Pool membership can change; an individual selection always stays pinned to its verified identity.
public enum DisplaySelection: Equatable, Sendable, RawRepresentable {
    case mode(DisplayMode)
    case claudeAccount(String)

    public init?(rawValue: String) {
        if rawValue.hasPrefix("mode/"), let number = Int(rawValue.dropFirst(5)),
           let mode = DisplayMode(rawValue: number) {
            self = .mode(mode)
        } else if rawValue.hasPrefix("account/claude/") {
            self = .claudeAccount(String(rawValue.dropFirst(8)))
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .mode(let mode): "mode/\(mode.rawValue)"
        case .claudeAccount(let id): "account/\(id)"
        }
    }

    public func text(snapshot: UsageSnapshot) -> String {
        switch self {
        case .mode(let mode): return MenuLabel.text(mode: mode, snapshot: snapshot)
        case .claudeAccount(let id):
            guard let account = account(id, snapshot: snapshot) else { return "—" }
            return Format.percent(Pool.share(label: nil, accounts: [account.usage]))
        }
    }

    public func title(snapshot: UsageSnapshot) -> String {
        switch self {
        case .mode(let mode): return mode.title
        case .claudeAccount(let id):
            guard let account = account(id, snapshot: snapshot) else { return "Claude account unavailable" }
            return "Claude: \(account.email)"
        }
    }

    public func tooltip(snapshot: UsageSnapshot) -> String {
        switch self {
        case .mode:
            return "\(title(snapshot: snapshot)). Estimated limiting quota percentages, not token capacity. Missing/expired accounts excluded. Animation indicates log activity only."
        case .claudeAccount:
            return "\(title(snapshot: snapshot)): \(text(snapshot: snapshot)). Pinned account’s limiting quota, including weekly limits. — means unavailable. Animation indicates log activity only."
        }
    }

    private func account(_ id: String, snapshot: UsageSnapshot) -> ClaudeAccount? {
        let matches = snapshot.claude.filter { $0.id == id && $0.usage.isConfigured }
        return matches.count == 1 ? matches.first : nil
    }

    public struct Choice: Equatable, Sendable {
        public let selection: DisplaySelection
        public let title: String
        public let enabled: Bool
    }

    /// Only Claude is multi-account; don't add redundant individual entries for single-source providers.
    /// Even with one Claude account, pool (future membership) and pinned account are distinct semantics.
    public static func choices(snapshot: UsageSnapshot, selected: DisplaySelection) -> [Choice] {
        var choices = DisplayMode.allCases.map { Choice(selection: .mode($0), title: $0.title, enabled: true) }
        for account in snapshot.claude where account.usage.isConfigured {
            guard let id = account.id,
                  snapshot.claude.filter({ $0.id == id }).count == 1 else { continue }
            let selection = DisplaySelection.claudeAccount(id)
            let suffix = account.usage.error.map { " (\($0))" } ?? ""
            let label = snapshot.claude.filter { $0.email == account.email && $0.usage.isConfigured }.count > 1
                ? "\(account.email) (slot \(account.slot))" : account.email
            choices.append(Choice(selection: selection, title: "Claude: \(label) — pinned\(suffix)", enabled: true))
        }
        if case .claudeAccount = selected, !choices.contains(where: { $0.selection == selected }) {
            choices.append(Choice(selection: selected, title: "Claude account unavailable — pinned", enabled: false))
        }
        return choices
    }
}

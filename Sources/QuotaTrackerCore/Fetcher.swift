import Foundation

/// Codex renews its file-backed login. Claude Code owns its credentials and their renewal.
public enum Fetcher {
    public static func fetchAll() async -> UsageSnapshot {
        async let codex = DirectSources.codex()
        async let claude = NativeClaude.fetch()
        async let kimi = DirectSources.kimi()
        return UsageSnapshot(codex: hideIfMissing(await codex), claude: await claude, kimi: hideIfMissing(await kimi))
    }

    private static func hideIfMissing(_ row: RowUsage) -> RowUsage {
        row.error == "not logged in" ? .notConfigured : row
    }
}

import Foundation

/// Codex renews its file-backed login. Claude Code owns its credentials; expired ones are renewed by
/// running Claude Code itself (see `NativeClaude.Refresher`).
public enum Fetcher {
    /// `claudeFolders`: user-added Claude config folders, on top of the auto-detected ones.
    public static func fetchAll(claudeFolders: [String] = []) async -> UsageSnapshot {
        async let codex = DirectSources.codex()
        async let claude = NativeClaude.fetch(folders: claudeFolders)
        return UsageSnapshot(codex: hideIfMissing(await codex), claude: await claude)
    }

    private static func hideIfMissing(_ row: RowUsage) -> RowUsage {
        row.error == "not logged in" ? .notConfigured : row
    }
}

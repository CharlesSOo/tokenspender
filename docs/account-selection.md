# Account selection integration

## Source selection

- Missing `~/.claude-swap-backup/sequence.json`, or a valid file with an empty `accounts` object: use native Claude Code. cswap need not be installed and is not invoked.
- Nonempty managed `accounts`: keep `cswap list --json`. Do not add the native current account to the pool again.
- Unreadable/malformed managed metadata, a missing/broken cswap executable, malformed/empty managed output, or managed authentication failures: show the managed error. Never silently fall back to another login.

Deleting a managed account is a cswap operation, not a display-selection operation. Once no managed accounts remain, native discovery resumes.

## Native Claude Code: no cswap required

Sign in normally through Claude Code. tokenspender reads the exact OAuth credential item for that profile using Apple's Security framework, without writing, exporting, refreshing, changing Keychain ACLs, or starting a new login system. Only `claudeAiOauth.accessToken` and millisecond `expiresAt` are decoded; refresh tokens and unrelated entries are not decoded or used. The credential JSON and access token remain in memory for the fetch, never preferences, caches, logs, or diagnostics.

### Profile boundary

The default macOS generic-password service is `Claude Code-credentials`, with the OS username (`USER` when present) as its account. For a nonempty configured profile, the service suffix is `-` plus the first eight hex characters of SHA-256 of the **raw NFC-normalized path string**. Trailing slashes and other textual differences are significant; do not resolve the path before hashing.

`CLAUDE_SECURESTORAGE_CONFIG_DIR`, when defined, takes precedence over `CLAUDE_CONFIG_DIR`. An explicitly empty secure-storage variable selects the default store. Otherwise, an empty/unset config variable uses the default. Set these in the environment of **tokenspender itself** when monitoring a non-default profile; shell-only settings are not automatically inherited by a login-item app. Absolute profile paths are supported. Relative paths (including literal `~/…`) show **unsupported profile path** rather than risking another process's working-directory interpretation. An explicit profile never falls back to the default Keychain item.

Only a genuinely absent Keychain item permits reading `.credentials.json` in the same selected secure-storage directory (default `~/.claude/.credentials.json`). Locked/denied/unavailable Keychain states and malformed/expired present credentials never trigger a fallback to a potentially stale file. File reads are bounded to 1 MiB. Missing OAuth credentials hide Claude; malformed credentials remain visible. API-key, setup-token environment overrides, and third-party OAuth sources are not native subscription-login sources for this integration.

### Consent and expiry

Background polling, opening the popover, and ordinary Refresh are noninteractive. Each read uses `LAContext.interactionNotAllowed`, plus the legacy login-Keychain process interaction switch (per-query flags alone are insufficient for legacy ACL dialogs). Reads are serialized off the main thread. Denied/locked states show **authorize in Settings**; unavailable Keychain also exposes the retry action.

Choose **Settings → Authorize Claude Code access…** to explicitly allow macOS's normal permission/unlock dialog for one read. Deny or cancel is respected; later background polls cannot prompt again. The app does not alter ACLs or choose “Always Allow” for the user. macOS may require approval again after the executable changes. Security.framework's synchronous Keychain operation has no cancellable deadline; an explicit consent dialog can wait for the user's decision, while AppKit stays responsive and overlapping refreshes are suppressed. Network requests have separate deadlines.

Expired credentials or HTTP 401 say **expired — log in Claude**. Renew/sign in using Claude Code, then Refresh. tokenspender never owns refresh-token rotation.

### Verified identity and quota

Using the **same access token**, GET `https://api.anthropic.com/api/oauth/profile`, require valid `account.uuid` and `organization.uuid`, then GET `/api/oauth/usage`. No identity is trusted from `~/.claude.json`, email labels, token hashes, or cached account metadata. A missing/unreadable profile fails closed: no quota is attributed to a guessed account. The stable pin key is account UUID + organization UUID, matching managed identity semantics.

Usage maps `five_hour` / `seven_day` utilization and reset timestamps; the menu-bar percentage is the minimum remaining quota across those windows. Headers use OAuth beta `oauth-2025-04-20` and the established `claude-code/2.1.0` compatibility user-agent. Provider bodies are never displayed as errors. HTTP 403/429 and network/timeouts show explicit quiet errors. Requests use an ephemeral, cache/cookie-free URLSession, 20-second request/resource deadlines, and reject redirects. There is no extra credential cache or history scan; two small read-only requests run per normal five-minute native refresh.

Conventions were checked against installed Claude Code 2.1.294 constants, maintained CodexBar `ClaudeConfigPaths`, `ClaudeOAuthCredentialModels`, `ClaudeOAuthUsageFetcher`, `KeychainSecurity`, and installed cswap profile/keychain source. Adapted CodexBar code is MIT-licensed; see `THIRD_PARTY_NOTICES.md`. No real credentials, Keychain consent, or provider calls were used during automated validation.

## Managed Claude identity

Usage remains `cswap list --json` schema v1. Its mutable `number` controls UI order and `email` is only a label/join check. Neither is persisted as identity: cswap supports moving/swapping slots.

The list schema does not expose account UUID. tokenspender reads only the identity projection of macOS cswap's `~/.claude-swap-backup/sequence.json`:

```json
{
  "accounts": {
    "1": {
      "email": "you@example.com",
      "uuid": "00000000-0000-0000-0000-000000000001",
      "organizationUuid": "00000000-0000-0000-0000-000000000002"
    }
  }
}
```

Account UUID + organization UUID distinguishes both multiple people in a shared organization and one person across organizations. Empty managed organization means personal identity. Duplicate/invalid identities or mismatched slot/email/organization leave that fetched row unpinnable; its usage stays in the pool/popover. Unverified rows do not accumulate burn-rate history. Metadata is read before invoking cswap; concurrent reconfiguration can temporarily make a pin unavailable until the next consistent refresh. No backup credentials are read directly by tokenspender.

This depends on cswap's metadata schema as well as its JSON output, verified against `json_output.account_row`, `models.AccountInfo`, `paths.get_backup_root`, and `ClaudeAccountSwitcher.sequence_file`. cswap still owns its own credential lifecycle.

## Display semantics and verification

Selection changes only the menu-bar display. Missing pins stay checked as unavailable in Settings, persist through refresh/relaunch, and recover when the same identity returns. All configured bars stay visible. A single Claude account has one pin and one pool choice: equal current percentages but different future-membership semantics. Existing AppKit visuals, accessibility, animations, and original-size critter remain unchanged. These percentages are quota estimates, not comparable token quantities.

`swift test` covers native-only/no-cswap routing, managed precedence without duplicate native rows, no error fallback, credential parsing, profile isolation, consent query policy, API failures, verified identity, weekly exhaustion, and prior pool/pin cases using synthetic fixtures. `swift build -c release` checks AppKit integration. Tests do not query the real Keychain or providers. Privacy-safe demo renders use `TOKENSPENDER_DEMO=1` and a private temporary snapshot directory; do not install the test build.

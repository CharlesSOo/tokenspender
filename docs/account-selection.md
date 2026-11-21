# Account selection integration

## Claude Code config folders

QuotaTracker shows one Claude row per Claude Code config folder:

- the default folder (`CLAUDE_CONFIG_DIR` unset: `~/.claude`, `~/.claude.json`);
- QuotaTracker's own `CLAUDE_SECURESTORAGE_CONFIG_DIR` / `CLAUDE_CONFIG_DIR`, if set;
- every `~/.claude-*` directory containing a `.claude.json` file (e.g. `~/.claude-me`, used via `CLAUDE_CONFIG_DIR=~/.claude-me`);
- every folder added under **Settings → Add Claude folder…** (removable from the same menu; kept in preferences).

Paths are deduped (a trailing slash is dropped from added folders); the default comes first, then the others sorted. A folder with no credentials is skipped. Any other failure shows a row labeled with the folder (e.g. `~/.claude-me`) so you know which login to fix. If two folders are signed into the same account, one row is shown, preferring a successful fetch. Keychain reads are serialized; network fetches run concurrently.

### Credentials

Sign in normally through Claude Code. Claude Code stores each folder's login as a generic-password Keychain item, written with `/usr/bin/security`; QuotaTracker reads it with the same tool (`security find-generic-password -w`), which is already on the item's access list, so no Keychain approval dialog appears and nothing changes when the app is rebuilt. QuotaTracker never writes, exports or changes the item or its ACL. Only `claudeAiOauth.accessToken` and millisecond `expiresAt` are decoded; refresh tokens and unrelated fields are ignored. The token stays in memory for the fetch and is never written to preferences, caches, logs or diagnostics. Each read has a 10-second deadline.

The default service is `Claude Code-credentials`, with the OS username (`USER` when present) as its account. For any other folder the service suffix is `-` plus the first eight hex characters of SHA-256 of the **raw NFC-normalized path string** (textual differences matter; the path is not resolved before hashing). `CLAUDE_SECURESTORAGE_CONFIG_DIR`, when defined, takes precedence over `CLAUDE_CONFIG_DIR`. Relative paths (including literal `~/…`) show **unsupported profile path**. A non-default folder never falls back to the default item.

Only a genuinely absent Keychain item permits reading `.credentials.json` in the same folder (default `~/.claude/.credentials.json`), bounded to 1 MiB. Other Keychain failures and malformed credentials never fall back to a possibly stale file. API-key and setup-token overrides are not subscription logins and are not used.

### Expired logins: delegated renewal

QuotaTracker never refreshes tokens itself. When a folder's login is past `expiresAt` or the API answers 401, it runs `claude -p /usage --output-format json` with `CLAUDE_CONFIG_DIR` set to that folder (unset for the default folder). That command makes no model call, but Claude Code renews its own login while starting. It runs at most once per folder every 10 minutes, in its own process group with stdin closed and output discarded. Its environment is QuotaTracker's minus `CLAUDE_SECURESTORAGE_CONFIG_DIR`, so only the folder decides which login renews. After 20 seconds the whole group gets SIGTERM, then SIGKILL 2 seconds later, so nothing it started outlives the deadline; `claude` is looked up in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then the login shell's `PATH` (read until the shell exits, under the same deadline). The Keychain is then read again.

An expired token is an internal detail: the UI never says "expired". While renewal is being tried, the row keeps its last good numbers, dimmed, with no hint, and the footer shows the normal **UPDATED …**. Only after two renewal runs in a row leave the login expired (about 10 minutes apart, given the throttle) is the folder treated as signed out: the row shows **signed out · run claude in ~/.claude-me** (the folder's label) under its dimmed numbers. A folder with no last good numbers shows that hint straight away instead of an error. A later success clears the count. Only network, timeout, 5xx and 429 failures make the footer say **OFFLINE · UPDATED …**.

### Verified identity, plan and limits

Using the same access token, QuotaTracker GETs `https://api.anthropic.com/api/oauth/profile`, requires valid `account.uuid` and `organization.uuid`, then GETs `/api/oauth/usage`. No identity is trusted from `~/.claude.json`, email labels or cached metadata; a missing profile fails closed. The stable pin key is account UUID + organization UUID. The row title adds the plan from `organization.plan_display_name` (e.g. `you@example.com · Ultra`), read every poll.

Which limits show comes from the usage response's `limits[]` each poll:

| `kind` | Row label |
|---|---|
| `session` | `5H` |
| `weekly_all` | `WK` |
| `weekly_scoped` | the model's `scope.model.display_name`, uppercased (e.g. `FABLE`) |

Other kinds and entries without a finite `percent` are ignored; a plan without a 5-hour limit has no `5H` bar. Only when `limits` is absent are the legacy `five_hour` / `seven_day` fields used.

Headers use OAuth beta `oauth-2025-04-20` and the `claude-code/2.1.0` user-agent. Provider bodies are never displayed as errors. Requests use an ephemeral, cache- and cookie-free URLSession with 20-second deadlines and reject redirects. Two small read-only requests run per folder per five-minute refresh.

Adapted CodexBar code is MIT-licensed; see `THIRD_PARTY_NOTICES.md`.

## Claude pool and menu bar

The popover leads with the token pool: its NOW as the large number, then WK and model-scoped bars. Each account with numbers (fresh, or last good while stale) is weighted by its plan's weekly capacity (Pro 1, Max 5, Ultra 10); an unknown or missing plan weighs 1. Lines are weighted means of percent left:

- **NOW**: per account the lower of 5H and WK left; an account without a 5-hour limit counts 5H as 100%.
- **WK**: the `weekly_all` limit.
- One line per model-scoped weekly limit (e.g. **FABLE**); these never lower NOW.

Accounts lacking a window are left out of that line. Rows with no numbers (errors, still loading) are left out entirely. Resets appear only on the account rows that follow as the breakdown; Codex is a separate section and never pooled.

The menu-bar number is the pool's NOW by default. Settings can instead show Codex, or pin one verified Claude account (that account's NOW). Missing pins stay checked as unavailable, persist through refresh and relaunch, and recover when the same identity returns. These percentages are quota estimates, not token balances.

## Verification

`swift test` covers folder discovery and Keychain-service hashing, one row per folder with failures labeled, duplicate-account merging, credential parsing, `limits[]` mapping, delegated renewal and its throttle, the renewal runner's process-group cleanup and environment, last-good merging, pool weighting and lines, footer wording, and pins, all with synthetic fixtures. Tests do not query the real Keychain, run `claude`, or call providers. Privacy-safe demo renders use `QUOTATRACKER_DEMO=1` (or `stale`, `signedout`, `single`) with `QUOTATRACKER_SNAPSHOT_DIR` set to a private temporary directory; without `QUOTATRACKER_DEMO` the same render uses live data.

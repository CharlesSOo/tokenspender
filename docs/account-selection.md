# Account selection integration

## Claude via claude-swap

Usage still comes from `cswap list --json` (schema v1); no new requests, credential reader, or account switching commands are introduced. `number` controls display order, `email` is only a label/join check. Neither is a stable identity: cswap supports moving/swapping slots.

The current list schema does not expose the account UUID. tokenspender therefore also reads the identity-only projection of `~/.claude-swap-backup/sequence.json` on macOS:

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

The saved selection is UUID + organization UUID, not email, slot, token, or list position. Organization UUID alone is insufficient: multiple users can share an organization. Account UUID alone is also insufficient when one user has multiple organization memberships. Empty organization means personal identity. Duplicate identities, invalid UUIDs, missing/corrupt metadata, or mismatched slot/email/organization leave that row unpinnable; its usage remains in the pool/popover. Unverified rows do not accumulate burn-rate history. Metadata is read after the list completes; a concurrent cswap reconfiguration can temporarily make a pin unavailable until the next consistent refresh.

This depends on cswap's metadata schema as well as its JSON output. Verified against its installed implementation: `json_output.account_row`, `models.AccountInfo`, `paths.get_backup_root`, and `ClaudeAccountSwitcher.sequence_file`. No credential directories or real metadata were inspected during development, and cswap was not executed by tests.

Selection changes only the menu-bar display. Missing pins remain checked as unavailable in Settings, persist across refresh/relaunch, and recover when the same identity returns. All configured account bars remain visible. With one Claude account there is one pinned choice and one pool choice: their current percentage coincides but future-membership semantics differ. Single-source Codex keeps its existing pool choice without a duplicate account entry. AppKit menu items retain native keyboard/accessibility behavior; the status item's accessible label and tooltip describe the selected display.

## Standalone Claude Code login: gap

No standalone native Claude authentication was added. A user with one Claude account can use cswap with one saved account, but still needs cswap today.

The simplest native macOS source is Claude Code's existing OAuth Keychain item (`Claude Code-credentials` for the default profile), not a Pi token or a guaranteed plaintext credentials file. The maintained cswap implementation documents profile-specific service-name hashing, `CLAUDE_CONFIG_DIR` / `CLAUDE_SECURESTORAGE_CONFIG_DIR` precedence, and distinct locked/denied/missing Keychain states. A reliable native read-only source needs bounded Keychain access, profile resolution, expiry/error handling, stable account attribution, and provider usage requests. Refresh should remain owned by Claude Code. That is a separate integration/product decision, not an implicit replacement for maintained cswap. No native tokens were read, refreshed, printed, or written for this work.

## Verification

`swift test` exercises synthetic identities, two accounts in one organization, single-account semantics, renamed labels and moved slots, removal/reappearance/slot reuse, weekly exhaustion, missing providers, and missing/corrupt/ambiguous metadata. `swift build` checks AppKit integration. Demo snapshots use only `example.com` labels and must be rendered into a private temporary directory with `TOKENSPENDER_DEMO=1`; no installation or registration-capable launch is needed.

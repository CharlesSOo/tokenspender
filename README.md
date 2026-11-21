# QuotaTracker

Native macOS menu-bar monitor for Claude and Codex quota. Every Claude account you use adds to one token pool.

<p>
  <img src="docs/screenshot-light.png" width="300" alt="Light appearance">
  <img src="docs/screenshot-dark.png" width="300" alt="Dark appearance">
</p>

## Install

```sh
git clone https://github.com/CharlesSOo/tokenspender.git
cd tokenspender
./install.sh
```

macOS 14+ and Xcode Command Line Tools. Installs to `/Applications` and starts at login.

## How it works

No setup and no permission prompts. QuotaTracker reads the logins your CLIs already have (Claude Code, Codex CLI) and asks each provider how much quota is left. Credentials are only sent to their own provider.

### Token pool

The large number is the token pool: how much of all your Claude accounts is available right now. Bigger plans count for more (Pro 1, Max 5, Ultra 10, by weekly capacity), so adding an account grows the pool. For each account it takes the lower of its 5-hour and weekly quota left; plans without a 5-hour limit only count the weekly one. The pool's weekly and per-model (e.g. Fable) limits get their own bars. It's an estimate across accounts, not a shared token balance.

The menu bar shows the pool. Settings can switch it to Codex or to a single account.

### Accounts

Each Claude Code config folder is one account: `~/.claude`, every `~/.claude-*` with a `.claude.json`, `$CLAUDE_CONFIG_DIR`, and any folder you add under Settings → Add Claude folder…. Each row shows the email, current plan, a bar, its limits and next reset. Which limits appear (5-hour, weekly, per-model) comes from the server on every poll, so plan changes show up on their own.

An account is either working or signed out. Claude Code's login renews only when you use it, so when one runs out QuotaTracker quietly runs `claude -p /usage` in that folder (no model call, at most every 10 minutes) and Claude Code renews it. Meanwhile the row keeps its last numbers, dimmed. Only if two renewals in a row fail does it say `signed out · run claude in ~/folder`. QuotaTracker never writes Claude credentials.

Codex logins renew automatically; rotated credentials are saved back to `~/.codex/auth.json` with owner-only permissions.

Offline, every row keeps its last good numbers (dimmed, saved across launches, no tokens stored) and refreshes when the network returns.

## Design

A single percentage in the menu bar, a little guy who eats and dances while you work. The animation reacts to session-log activity, not measured token spend. Light and dark follow the system.

![Menu-bar percentage](docs/menubar.png)

| Eating | Dancing |
|---|---|
| ![Eating animation](docs/animation.gif) | ![Dancing animation](docs/dancing.gif) |

## Footprint

Pure AppKit. ~450 KiB bundle, ~20 MiB settled memory, 0% idle CPU.

MIT. Provider parsing adapted from [CodexBar](https://github.com/steipete/CodexBar), see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Not affiliated with Anthropic or OpenAI.

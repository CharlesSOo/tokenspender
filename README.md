# QuotaTracker

Native macOS menu-bar monitor for Claude and Codex quota remaining.

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

Reads the credentials your CLIs already have (Claude Code, Codex CLI) and asks each provider for remaining quota. Credentials are only sent to their provider. Codex access tokens renew automatically; rotated credentials are saved back to `~/.codex/auth.json` with owner-only permissions.

Each Claude Code config folder is one account row with its current plan: `~/.claude`, every `~/.claude-*` with a `.claude.json`, `$CLAUDE_CONFIG_DIR`, and any folder added under Settings → Add Claude folder…. An account is either working or signed out. When a Claude login runs out, QuotaTracker quietly runs `claude -p /usage` for that folder (no model call, at most every 10 minutes) so Claude Code renews it; meanwhile the row keeps its last numbers, dimmed. Only if two renewals in a row fail does the row say `signed out · run claude in ~/folder`. Which limits show (5-hour, weekly, per-model) comes from the server each poll.

All Claude accounts form one token pool, the large number at the top: each account counts by its plan's weekly capacity (Pro 1, Max 5, Ultra 10; an unknown plan counts 1). NOW is the weighted mean of each account's lower of 5-hour and weekly quota left (no 5-hour limit counts as 100%); the weekly line and each per-model weekly limit get their own line. The menu-bar number is the pool's NOW, an estimate rather than a shared token balance; Settings can switch it to Codex or a single account. Below the pool, each account is a compact row: its own NOW, a thin bar, and its limits and next reset. The animation reacts to session-log activity, not measured token spend. Offline, each row keeps its last good numbers (dimmed, saved across launches, no tokens stored) and refreshes when the network returns.

## Design

A single percentage in the menu bar, a little guy who eats and dances while you work. Light and dark follow the system.

![Menu-bar percentage](docs/menubar.png)

| Eating | Dancing |
|---|---|
| ![Eating animation](docs/animation.gif) | ![Dancing animation](docs/dancing.gif) |

## Footprint

Pure AppKit. ~450 KiB bundle, ~20 MiB settled memory, 0% idle CPU.

MIT. Provider parsing adapted from [CodexBar](https://github.com/steipete/CodexBar), see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Not affiliated with Anthropic or OpenAI.

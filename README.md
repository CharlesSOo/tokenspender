# tokenspender

Native macOS menu-bar monitor for Claude, Codex and Kimi quota remaining.

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

macOS 14+ and Xcode Command Line Tools. Installs to `~/Applications` and starts at login.

## How it works

Reads the credentials your CLIs already have (Claude Code, Codex CLI, Pi for Kimi) and asks each provider for remaining quota. Nothing is stored or sent anywhere else. Claude needs a one-time Keychain approval in Settings. Multiple Claude accounts via [claude-swap](https://github.com/realiti4/claude-swap), see [docs](docs/account-selection.md).

The menu-bar number is an estimate across accounts, not a shared token balance. Per-account bars and reset times are in the popover. The animation reacts to session-log activity, not measured token spend.

## Footprint

Pure AppKit. ~450 KiB bundle, ~20 MiB settled memory, 0% idle CPU.

MIT. Provider parsing adapted from [CodexBar](https://github.com/steipete/CodexBar), see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Not affiliated with Anthropic, OpenAI or Moonshot AI.

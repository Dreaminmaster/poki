<p align="center">
  <img src="docs/images/poki-icon.png" width="64" height="64" alt="Poki icon">
</p>

<h1 align="center">Poki uses your iPhone like you do</h1>

<p align="center">
  <img src="docs/images/poki-home.gif" width="500" alt="Poki website home page animation">
</p>

<p align="center">
  English | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.es.md">Español</a><br>
  <a href="https://poki.bot">poki.bot</a>
</p>

<!-- badges:start -->
<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="License: AGPL-3.0-only"></a>
  <a href="https://github.com/JosssphZhou/poki/stargazers"><img src="https://img.shields.io/github/stars/JosssphZhou/poki" alt="GitHub stars"></a>
  <a href="https://github.com/JosssphZhou/poki/forks"><img src="https://img.shields.io/github/forks/JosssphZhou/poki" alt="GitHub forks"></a>
  <a href="https://github.com/JosssphZhou/poki/issues"><img src="https://img.shields.io/github/issues/JosssphZhou/poki" alt="GitHub issues"></a>
  <a href="https://github.com/JosssphZhou/poki/releases"><img src="https://img.shields.io/badge/Poki_App-0.4.4_Beta-blue" alt="Poki App 0.4.4 Beta"></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20Windows-lightgrey" alt="Platform: iOS, macOS and Windows">
</p>
<!-- badges:end -->

<p align="center">
  <strong>If Poki is useful to you, click ★ Star to support the project.</strong>
</p>

## What Poki is

Poki is an open-source iPhone agent that operates your entire iPhone for you. The Poki app runs directly on your iPhone, reads the screen, and taps, types, and scrolls inside real apps using your own model account. You choose how it asks for permission; payments, deletions, and Wallet actions always stop for your confirmation.

## Why Poki

- **Skip multi-app tapping for everyday errands.** Ask Poki in chat, hold the Action Button, or trigger Siri to look things up in the built-in browser, check tomorrow's weather, or create a note. On iPhone Duo, Poki works across two apps side by side in Split View.
- **Run saved skills by tap or by voice.** Launch a saved skill from the home screen instead of repeating the same steps every day, or start a hands-free spoken chat with Talk to Poki while Dynamic Island tracks each step.
- **Automate your real phone without keeping a computer on.** Once installed from a Mac or Windows PC, Poki runs standalone on your iPhone with no computer attached and pauses on the Lock Screen or in Dynamic Island whenever a step needs approval.

## How to use

### Install Poki on your iPhone

1. **Install once from a Mac or Windows PC.** Connect and unlock your iPhone over USB (a free Apple Account works), then tell your coding agent, such as Claude Code or Codex:

   ```text
   Install Poki on my iPhone from https://github.com/JosssphZhou/poki
   ```

   Or download [Poki Setup](https://github.com/JosssphZhou/poki/releases) for macOS (`.dmg`) or Windows (`.exe`) and follow the window.
2. **Connect and add your model account.** Accept **Trust**, turn on Developer Mode and Automation Mode when iOS asks, set up an external connection routing `10.7.0.1` back to your iPhone (such as free LocalDevVPN), and sign in with ChatGPT Plus or Pro or paste an API key (Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter, OpenCode Go, or an OpenAI-compatible server).
3. **Run your first task.** Open Poki and send:

   ```text
   Create a new note in Notes titled "Poki Demo" with these three lines: Milk, Eggs, Coffee. Open the note when finished. Leave existing notes unchanged.
   ```

   Open Notes afterward to confirm "Poki Demo" exists with those three lines.

<details>
<summary>Requirements, updating, common questions, and guides</summary>

| | Requirement |
| --- | --- |
| iPhone | iOS 18 or later (iPhone XS, XR, SE 2nd gen or newer; iPadOS 18+ on iPad). Tested on physical iPhones with iOS 27. |
| Computer | Mac with macOS 14+ (Node.js 24+ for agent install) or Windows PC (x64) with Apple Devices or iTunes. |
| Cable and account | USB data cable and an Apple Account. Poki Setup renews free 7-day signatures while open, or sign in inside Poki. |
| Connection | External connection routing `10.7.0.1` back to the iPhone (LocalDevVPN, Karing, or Shadowrocket). |
| Model account | ChatGPT Plus/Pro sign-in, an API key (Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter, OpenCode Go), or an OpenAI-compatible server. |

- Full installation, updating, FAQ, known issues, and roadmap: [Poki iPhone App Guide](docs/iphone-guide.md)
- Changelog and version history: [CHANGELOG.md](CHANGELOG.md)
- Agent installer skill and Poki Setup: [install-poki skill](skills/install-poki/SKILL.md) and [Poki Setup](desktop/README.md)
- Verification, limits, and release channels: [Verification](docs/verification.md) and [Release channels](docs/release-channels.md)
- Earlier computer-driven tools (no longer updated): [Poki MCP and Poki Agent](docs/poki-mcp.md)

</details>

## Community

- **Questions and ideas:** Join [GitHub Discussions](https://github.com/JosssphZhou/poki/discussions).
- **Bugs and requests:** Open an issue in [GitHub Issues](https://github.com/JosssphZhou/poki/issues).
- **Contribute code:** Read [CONTRIBUTING.md](CONTRIBUTING.md).

See all contributors in [CONTRIBUTING.md](CONTRIBUTING.md#contributors).

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. Open source under [AGPL-3.0-only](LICENSE). Brand assets are governed by [BRAND.md](BRAND.md). See [Poki iPhone App Guide](docs/iphone-guide.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and [Disclaimer](docs/iphone-guide.md#disclaimer).

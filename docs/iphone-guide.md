# Poki iPhone App Guide

English | [简体中文](iphone-guide.zh-CN.md) | [繁體中文](iphone-guide.zh-TW.md) | [日本語](iphone-guide.ja.md) | [한국어](iphone-guide.ko.md) | [Español](iphone-guide.es.md)

This guide covers full system requirements, installation details, updating, common questions, known limits, and task examples for the Poki iPhone app.

See what changed in each version in [CHANGELOG.md](../CHANGELOG.md).

## What you need

| | Requirement |
| --- | --- |
| iPhone | iOS 18 or later, so iPhone XS, XR, SE (2nd generation) or newer. Poki has been tested on physical iPhones with iOS 27. |
| Computer | A Mac with macOS 14 or later, or a Windows PC (x64) with Apple Devices or iTunes installed. The agent install on a Mac also needs Node.js 24 or later. |
| Cable and account | A USB data cable and an Apple Account. With a free account the signature lasts 7 days, and Poki Setup can renew it for you. |
| Connection | A VPN app on the iPhone that routes `10.7.0.1` back to the iPhone. The free LocalDevVPN from the App Store works, and so do Karing and Shadowrocket set up through Poki's instructions. |
| Model account | Your own. Signing in with a ChatGPT Plus or Pro plan is the easiest start. You can also paste an API key from Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter, or OpenCode Go, or use your own OpenAI-compatible server. A Claude subscription cannot sign in, so use an Anthropic API key instead. |

On iOS 27 and later Poki controls the iPhone through its native services. On iOS 18 to 26 it uses an XCTest session instead, which needs UI Automation turned on in the iPhone's Developer settings. The app also installs on iPad with iPadOS 18 or later.

The iPhone app uses your own model account. Your coding agent's subscription does not automatically connect that account to Poki. If you only want Poki MCP in your existing coding agent, follow [MCP installation](install.md) instead; MCP uses that client's model access.

## Installation details

### One-click installation (recommended)

You only need to connect and unlock your iPhone, sign in when prompted, and complete the iPhone permissions, local connection, and model-account steps.

Tell your agent, such as Claude Code or Codex:

```text
Install Poki on my iPhone from https://github.com/JosssphZhou/poki
```

The agent follows the [install-poki skill](../skills/install-poki/SKILL.md) and runs `bin/install-iphone.mjs`, which does every step it can by itself. You only do what iOS asks of you: type your Apple Account into a Poki Setup window on the Mac, tap Trust and turn on Developer Mode on the iPhone, trust the developer, and open Poki. When Poki first opens it asks for Automation Mode: tap Continue and enter the iPhone passcode. If you cancel, turn Poki on again to be asked again. The agent tells you each step in a sentence when it comes up. A free Apple Account works.

The current installer selects Beta. Historical Stable, Alpha, and Pre-alpha preferences also resolve to Beta. It stops if no Beta is available. Older installed copies of Poki Setup may retain their previous channel behavior; read the version selected by your run.

No Node.js 24, or on Windows? The same prompt works once Poki Setup is installed: the agent then uses the command line tool inside Poki Setup. Poki Setup's own menu also copies a prompt for your agent (`Poki > Copy Prompt for Your Agent` on a Mac, `Settings > Use an agent` on Windows).

If GitHub answers 403 or 429 while the installer reads Poki's releases, it is usually GitHub's hourly limit on anonymous requests, which everyone on your network shares. Switch to another network or proxy node and run it again, or wait an hour.

### With Poki Setup

Download Poki Setup for macOS (`.dmg`) or Windows (`.exe`, contributed by [ZhehanZhang](https://github.com/ZhehanZhang)) from the newest [Beta release](https://github.com/JosssphZhou/poki/releases) that includes the installer, then follow its window. See [Poki Setup](../desktop/README.md) for the steps.

### Run your first task

After the installer has verified the installed version and you have finished the local connection and model-account steps, open Poki and send:

```text
Create a new note in Notes titled "Poki Demo" with these three lines: Milk, Eggs, Coffee. Open the note when finished. Leave existing notes unchanged.
```

Check the new note in Notes: the title must be "Poki Demo" and the body must contain Milk, Eggs, and Coffee on separate lines. A completion message alone is not proof. If Notes is unavailable or setup is incomplete, finish that step first. After an interruption, check whether the note already exists before trying again.

## Common questions

**Can I install Poki from Windows?** Yes. Poki Setup for Windows installs, pairs, and renews Poki like the Mac version. Install Apple Devices or iTunes first so the PC can find the iPhone. See [Poki Setup](../desktop/README.md).

**Do I still need the computer after installing?** Not to run tasks: Poki works on the iPhone alone. With a free Apple Account, keep Poki Setup open on the computer so it can renew the signature each week, or sign in to your Apple Account in Poki so the iPhone renews itself (if sign-in fails, use Poki Setup on the computer). See [What to keep running](../skills/install-poki/SKILL.md#what-to-keep-running).

**Does a free Apple Account work, and what is the 7-day limit?** A free account works, but Apple signs apps from it for 7 days only. While it is open, Poki Setup renews Poki every 6 hours once 2 days or fewer are left, as long as the computer is awake and the iPhone is reachable. Without a renewal, Poki stops opening when the signature ends, so it warns you in its last 2 days. See [No paid developer account](../skills/install-poki/SKILL.md#no-paid-developer-account).

**Which iPhone and iOS do I need?** iOS 18 or later, so iPhone XS, XR, SE (2nd generation) or newer, and iPad with iPadOS 18 or later. Physical testing so far has been on iOS 27; iOS 18 to 26 use a different control path that has not been tested on a physical iPhone yet. See [Verification and known limits](verification.md).

**Do I need my own model account?** Yes. Sign in with a ChatGPT Plus or Pro plan, or paste an API key from Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter, or OpenCode Go, or use your own OpenAI-compatible server. Talking with Poki also needs a voice model key. See [What you need](#what-you-need).

**No update shows up, for example on a network in mainland China. What now?** Poki looks for updates on GitHub, and some networks cannot reach it or hit GitHub's 403 and 429 limits. Try another network or proxy node, or update from the computer with Renew in Poki Setup. See [Update Poki](#update-poki).

**Will Poki change things on my iPhone, and does it ask first?** Poki works in your real apps and does what you ask, including sending messages, and the screen contents go to the model service you set up. Payments, deletions in menus and confirmation dialogs, and actions in Wallet always need your confirmation. For other sensitive steps, such as sending a message or typing a password, you choose in `Settings > Approvals` how Poki asks, or whether it asks. See [Known issues](#known-issues).

## Update Poki

- **On the iPhone.** Open Poki's signing and updates page: `Settings > Signing & Updates` in current builds. Older builds may place it under Connection. When a newer build is out, the page offers to download and install it. If it asks you to sign in first, Poki was installed from a computer and the iPhone does not have your Apple Account yet. Sign in with the account you installed with, or update from the computer instead.
- **From the computer.** Renew in Poki Setup installs the newest build on its channel over the installed app. On a Mac you can also tell your agent "Update Poki on my iPhone"; the install-poki skill has a separate update path that checks the installed version and signing identity first.
- If an update stops at "Finishing the update", swipe Poki away in the app switcher and open it again, then check the version in Settings. If the version did not change, update from Poki Setup on the computer. Do not delete Poki to fix an update: deleting it deletes its conversations.

The release channels and how a build moves from Alpha to Beta are in [Release channels](release-channels.md).

## Try a task

Open Poki and type a task in the message field, such as "Check tomorrow's weather and tell me if I need an umbrella", or tap one of the apps on the home page to start a task in it. Poki works in the app on your screen, shows each step in the Dynamic Island and on the Lock Screen, and asks for approval according to your settings.

You can also call Poki without opening it: press and hold the Action Button to talk to it, or use Talk to Poki and Send Task to Poki from Shortcuts and Siri. A task sent that way replies with a notification. On iPhone Duo in Split View, Poki can work across two apps side by side.

> **Note:** Poki controls your real iPhone. If you ask it to send messages or make payments, it will.

## Known issues

- Poki operates your real iPhone. If you ask it to send messages or make payments, it will. Screen contents are sent to the model service you set up.
- If you cannot sign in to your Apple Account on the iPhone, renew and update from Poki Setup on the computer.
- Physical iPhone support has been verified only on iPhones using the Chinese interface, in portrait orientation. Landscape is not supported.
- This release has not been tested on a physical iPhone below iOS 27, or on an iPad. On older and smaller iPhones, the three-dimensional bear and the home page animations may run warmer or slower. Low Power Mode and Reduce Motion show a still picture of the bear instead.
- With a free Apple Account the signature lasts 7 days. Keep Poki Setup on the computer able to reach the iPhone, or renew by hand before it expires.
- Reading Poki's releases from GitHub can fail with 403 or 429, usually because many people share one network. Switch network or proxy node and try again, or wait an hour.

More limits, with test results, are in [Verification and known limits](verification.md).

### Start automation after a restart with Clash Mi

If Poki shows **Turn On Loopback** after an iPhone restart even though Clash Mi is connected, use LocalDevVPN for the first startup of automation.

1. Unlock your iPhone, connect to Wi-Fi, and disconnect Clash Mi.
2. Connect LocalDevVPN. In Poki, open **Settings > Setup** and turn on **Automation** if it is off.
3. Open a chat and tap the message field to start preparing the developer disk image. In **Settings > Advanced > Log**, wait for a new `[runner] running` entry from this attempt before switching VPNs.
4. Leave **Automation** on. Disconnect LocalDevVPN and reconnect Clash Mi. Ask Poki to calculate 37 × 19 in Calculator and check that Calculator shows 703.

If Poki shows **Enter Your Passcode Next** when you turn on automation or run the first task, tap **Continue**. If Poki is waiting for confirmation and the alert does not appear, open **Settings > Setup** and tap **Continue** there. Enter your iPhone passcode when iOS asks.

Poki needs to reach the iPhone's developer services to mount the developer disk image after a restart. Once the image is mounted, Poki can use it for local automation. If the prompt returns after the next restart, repeat these steps. If the switch still fails, open **Settings > Advanced > Diagnostics** and compare the **Reflected RemotePairing** results with each VPN.

## Roadmap

This lists directions, not dates. Released features are documented in [CHANGELOG.md](../CHANGELOG.md).

**Released in 0.4 Beta**

- The iPhone app runs tasks without the computer after setup, with approvals on the Lock Screen and in the Dynamic Island.
- Install with your agent or Poki Setup on a Mac or Windows PC, using a free Apple Account.
- Native control on iOS 27 and later, plus web tasks in Poki's built-in browser.
- A home page with the three-dimensional bear, voice conversations, the Action Button, archived conversations, iPhone Duo Split View, adjustable interface size, and dark mode.

**In progress**

- More reliable update delivery and unified update handling.
- The interface in more languages.

**Planned**

- More iPhones, iOS versions, and screen languages verified on real devices.
- More model providers.

## Other tools

[Poki MCP](poki-mcp.md) connects a computer's agent to an iPhone or the iOS Simulator; this earlier tool is no longer updated.

[Poki Agent](poki-mcp.md#try-a-task-with-poki-agent) is the terminal agent with iMessage and Telegram channels; setup and usage remain in the linked guide.

## Disclaimer

Poki is an independent open-source project. It is not affiliated with, or endorsed by, Apple, OpenAI, or the makers of any app or website it operates. iPhone is a trademark of Apple Inc.

Automating third-party apps and websites may violate their terms of service. Decide for yourself whether to use Poki with a given service. You are responsible for what it does on your device and accounts, including messages it sends, changes it makes, and any account restrictions that result.

Poki is provided "as is", without warranty, as set out in the AGPL-3.0 license.

## License

Poki's code is open source under the [AGPL-3.0-only license](../LICENSE).

The Poki bear, the app icon, and Poki's other artwork are not covered by that license. You can use screenshots to write about Poki; a fork needs its own name and artwork. See [BRAND.md](../BRAND.md).

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. Open-source dependencies and third-party assets retain their respective licenses; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). To contribute, see [CONTRIBUTING.md](../CONTRIBUTING.md).

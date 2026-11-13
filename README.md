<p align="center">
  <img src="docs/images/poki-icon.png" width="72" height="72" alt="Poki icon">
</p>

<h1 align="center">Poki uses your iPhone like you do</h1>

<p align="center">
  <img src="docs/images/poki-home.gif" width="720" alt="Poki website home page animation">
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
  <a href="https://github.com/JosssphZhou/poki/releases"><img src="https://img.shields.io/github/v/release/JosssphZhou/poki?sort=date&amp;display_name=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20Windows-lightgrey" alt="Platform: iOS, macOS and Windows">
</p>
<!-- badges:end -->

Poki is an agent that operates an iPhone the way a person does. It reads the screen, taps, types and scrolls in real apps, and asks you before anything sensitive.

**The Poki app** runs on the iPhone itself. You give it a task in a chat, and it works in your other apps. You install it once from a Mac or a Windows PC, and after that it runs tasks on the iPhone without the computer.

Poki MCP, the earlier way to drive an iPhone from an agent on a Mac, is no longer updated. It is kept as it is near the end of this page, under [Poki MCP](#poki-mcp-earlier-computer-connection-no-longer-updated).

See what changed in each version in [CHANGELOG.md](CHANGELOG.md).

## Install Poki on your iPhone

You need a computer once, to install Poki: a Mac or a Windows PC.

- **On a Mac**, tell your agent to install Poki, or download Poki Setup for macOS and click through it.
- **On Windows**, download Poki Setup for Windows and follow its window. Install Apple Devices or iTunes first, so the PC can find the iPhone over USB. Your agent can also run Poki Setup's own command line tool.
- **After that**, Poki runs tasks on the iPhone without the computer. With a free Apple Account the signature lasts 7 days, and Poki Setup renews it while it stays open on the computer. See [Common questions](#common-questions).

### With your agent (recommended)

Tell your agent, such as Claude Code or Codex:

```text
Install Poki on my iPhone from https://github.com/JosssphZhou/poki
```

The agent follows the [install-poki skill](skills/install-poki/SKILL.md) and runs `bin/install-iphone.mjs`, which does every step it can by itself. You only do what iOS asks of you: type your Apple Account into a Poki Setup window on the Mac, tap Trust and turn on Developer Mode on the iPhone, trust the developer, and open Poki. When Poki first opens it asks for Automation Mode: tap Continue and enter the iPhone passcode. If you cancel, turn Poki on again to be asked again. The agent tells you each step in a sentence when it comes up. A free Apple Account works.

The installer uses the Alpha channel unless you ask your agent for another one, such as Beta. Alpha gets each build first and Beta gets the same build after more testing.

No Node.js 24, or on Windows? The same prompt works once Poki Setup is installed: the agent then uses the command line tool inside Poki Setup. Poki Setup's own menu also copies a prompt for your agent (Poki > Copy Prompt for Your Agent on a Mac, Settings > Use an agent on Windows).

If GitHub answers 403 or 429 while the installer reads Poki's releases, it is usually GitHub's hourly limit on anonymous requests, which everyone on your network shares. Switch to another network or proxy node and run it again, or wait an hour.

### With Poki Setup

Prefer clicking through it yourself? Download Poki Setup for macOS (`.dmg`) or Windows (`.exe`, contributed by [ZhehanZhang](https://github.com/ZhehanZhang)) from the [Alpha release](https://github.com/JosssphZhou/poki/releases/tag/app-alpha-latest) and follow its window. The Beta release carries the same Poki Setup files. Until you pick a channel in its Settings, Poki Setup installs the newest Stable release, or the Beta while there is no Stable release yet. What Poki Setup does, step by step, is in [Poki Setup](desktop/README.md).

### What you need

| | Requirement |
| --- | --- |
| iPhone | iOS 18 or later, so iPhone XS, XR, SE (2nd generation) or newer. Poki has been tested on physical iPhones with iOS 27. |
| Computer | A Mac with macOS 14 or later, or a Windows PC (x64) with Apple Devices or iTunes installed. The agent install on a Mac also needs Node.js 24 or later. Xcode is not needed. |
| Cable and account | A USB data cable and an Apple Account. With a free account the signature lasts 7 days, and Poki Setup can renew it for you. |
| Connection | A VPN app on the iPhone that routes 10.7.0.1 back to the iPhone. The free LocalDevVPN from the App Store works, and so do Karing and Shadowrocket set up through Poki's instructions. |
| Model account | Your own. Signing in with a ChatGPT Plus or Pro plan is the easiest start. You can also paste an API key from Anthropic, OpenAI, Gemini, DeepSeek or OpenRouter, or use your own OpenAI-compatible server. A Claude subscription cannot sign in, so use an Anthropic API key instead. |

On iOS 27 and later Poki controls the iPhone through its native services. On iOS 18 to 26 it uses an XCTest session instead, which needs UI Automation turned on in the iPhone's Developer settings. The app also installs on iPad with iPadOS 18 or later.

### Common questions

**Can I install Poki from Windows?** Yes. Poki Setup for Windows installs, pairs and renews Poki like the Mac version. Install Apple Devices or iTunes first so the PC can find the iPhone. See [Poki Setup](desktop/README.md).

**Do I still need the computer after installing?** Not to run tasks: Poki works on the iPhone alone. With a free Apple Account, keep Poki Setup open on the computer so it can renew the signature each week, or sign in to your Apple Account in Poki so the iPhone renews itself (that first sign-in can fail in 0.4.0; see [Known issues](#known-issues)). See [What to keep running](skills/install-poki/SKILL.md#what-to-keep-running).

**Does a free Apple Account work, and what is the 7-day limit?** A free account works, but Apple signs apps from it for 7 days only. While it is open, Poki Setup renews Poki every 6 hours once 2 days or fewer are left, as long as the computer is awake and the iPhone is reachable. Without a renewal, Poki stops opening when the signature ends, so it warns you in its last 2 days. See [No paid developer account](skills/install-poki/SKILL.md#no-paid-developer-account).

**Which iPhone and iOS do I need?** iOS 18 or later, so iPhone XS, XR, SE (2nd generation) or newer, and iPad with iPadOS 18 or later. Physical testing so far has been on iOS 27; iOS 18 to 26 use a different control path that has not been tested on a physical iPhone yet. See [Verification and known limits](docs/verification.md).

**Do I need my own model account?** Yes. Sign in with a ChatGPT Plus or Pro plan, or paste an API key from Anthropic, OpenAI, Gemini, DeepSeek or OpenRouter, or use your own OpenAI-compatible server. Talking with Poki also needs a voice model key. See [What you need](#what-you-need).

**No update shows up, for example on a network in mainland China. What now?** Poki looks for updates on GitHub, and some networks cannot reach it or hit GitHub's 403 and 429 limits. Try another network or proxy node, or update from the computer with Renew in Poki Setup. See [Update Poki](#update-poki).

**Will Poki change things on my iPhone, and does it ask first?** Poki works in your real apps and does what you ask, including sending messages, and the screen contents go to the model service you set up. Payments, deletions and actions in Wallet always need your confirmation. For other sensitive steps, such as sending a message or typing a password, you choose in Settings > Approvals how Poki asks, or whether it asks. See [Known issues](#known-issues).

## Update Poki

- **On the iPhone.** Open Poki's signing and updates page: Settings > Connection > Signing & Updates in 0.4.0, or the Signing page in Settings in 0.3.1. When a newer build is out, the page offers to download and install it. If it asks you to sign in first, Poki was installed from a computer and the iPhone does not have your Apple Account yet. Sign in with the account you installed with, or update from the computer instead.
- **From the computer.** Renew in Poki Setup installs the newest build on its channel over the installed app. On a Mac you can also tell your agent "Update Poki on my iPhone"; the install-poki skill has a separate update path that checks the installed version and signing identity first.
- If an update stops at "Finishing the update", swipe Poki away in the app switcher and open it again, then check the version in Settings. If the version did not change, update from Poki Setup on the computer. Do not delete Poki to fix an update: deleting it deletes its conversations.

The release channels and how a build moves from Alpha to Beta are in [Release channels](docs/release-channels.md).

## Known issues

- Poki operates your real iPhone. If you ask it to send messages or make payments, it will. Screen contents are sent to the model service you set up.
- In 0.4.0, signing in to your Apple Account for the first time on the iPhone can report that a Mac is needed, because Apple stopped accepting the older Mac identity Poki signs in with. If you are already signed in, updating on the iPhone works as usual. Otherwise renew and update from Poki Setup on the computer.
- Physical iPhone support has been verified only on iPhones using the Chinese interface, in portrait orientation. Landscape is not supported.
- This release has not been tested on a physical iPhone below iOS 27, or on an iPad. On older and smaller iPhones, the three-dimensional bear and the home page animations may run warmer or slower. Low Power Mode and Reduce Motion show a still picture of the bear instead.
- With a free Apple Account the signature lasts 7 days. Keep Poki Setup on the computer able to reach the iPhone, or renew by hand before it expires.
- Reading Poki's releases from GitHub can fail with 403 or 429, usually because many people share one network. Switch network or proxy node and try again, or wait an hour.

More limits, with test results, are in [Verification and known limits](docs/verification.md).

## Try a task

Open Poki and type a task in the message field, such as "Check tomorrow's weather and tell me if I need an umbrella", or tap one of the apps on the home page to start a task in it. Poki works in the app on your screen, shows each step in the Dynamic Island and on the Lock Screen, and stops to ask before a sensitive step.

You can also call Poki without opening it: press and hold the Action Button to talk to it, or use Talk to Poki and Send Task to Poki from Shortcuts and Siri. A task sent that way replies with a notification.

> **Note:** Poki controls your real iPhone. If you ask it to send messages or make payments, it will.

## Roadmap

This lists directions, not dates.

**Done, up to the 0.4.0 Beta**

- The Poki app on the iPhone, which works without a Mac after setup, with approvals on the Lock Screen and in the Dynamic Island.
- One-step install by your agent or Poki Setup on a Mac or Windows PC, with no Xcode and a free Apple Account.
- Native control on iOS 27 and later.
- Poki MCP, Poki Agent, iMessage and Telegram channels, and routes Poki learns and replays. Poki MCP is now kept as it is, without updates.
- Remote connections over LAN and Tailscale.
- The 0.4.0 interface: the home page with the three-dimensional bear, talking with Poki, the Action Button, archive and dark mode.

**Next**

- Updates come from Poki's own download source, with GitHub kept as a backup.
- One update channel in place of several.
- Voice only listens, speaks and looks. Actions on the phone go to the same text models that run tasks today.
- The interface in more languages.

**Later**

- More iPhones, iOS versions and screen languages verified on real devices.
- More model providers.

## Docs

| Topic | Read |
| --- | --- |
| What changed in each version | [CHANGELOG.md](CHANGELOG.md) |
| Installing the iPhone app with an agent | [install-poki skill](skills/install-poki/SKILL.md) |
| Poki Setup for Mac and Windows | [Poki Setup](desktop/README.md) |
| Release channels and how builds are promoted | [Release channels](docs/release-channels.md) |
| Poki MCP installation, other MCP clients, and troubleshooting (no longer updated) | [Install guide](docs/install.md) |
| Poki Agent, models, iMessage, and Telegram | [Run Poki Agent](agent/README.md) |
| MCP tool reference | [Tool behavior](docs/tools.md) |
| Environment variables and sessions | [Configuration](docs/configuration.md) |
| USB pairing, Developer Mode, and Wi-Fi | [Physical iPhone setup](docs/physical-iphone.md) |
| Test results, known limits, and disclaimers | [Verification](docs/verification.md) |
| Bridge architecture | [Native bridge](native/NATIVE.md) and [simulator adapter](native/simulator.md) |
| Roadmap | [Roadmap](#roadmap) |

## Star History

<a href="https://www.star-history.com/?repos=JosssphZhou%2Fpoki&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&theme=dark&legend=top-left">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
    <img alt="Star History chart" src="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
  </picture>
</a>

## Core contributors

<!-- CORE-CONTRIBUTORS:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=240" width="120" height="120" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a><br />Filed Poki's first issue, <a href="https://github.com/JosssphZhou/poki/issues/1">#1</a>, on iOS 18.6.2: screenshots worked, accessibility and touch did not, and the clear split made it easy to follow.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=240" width="120" height="120" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a><br />The great co-creator of Poki.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=240" width="120" height="120" alt="edge369"/><br /><sub><b>edge369</b></sub></a><br />Made Poki run on a router in <a href="https://github.com/JosssphZhou/poki/pull/14">#14</a>, so Telegram can drive the iPhone with the Mac powered off; <a href="https://github.com/JosssphZhou/poki/pull/15">#15</a>, <a href="https://github.com/JosssphZhou/poki/pull/17">#17</a> and <a href="https://github.com/JosssphZhou/poki/issues/19">#19</a> followed.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=240" width="120" height="120" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a><br />Reported in <a href="https://github.com/JosssphZhou/poki/issues/6">#6</a> that usbmuxd listed no iPhone on macOS 27.2; Poki now says so plainly and why a helper stops early (<a href="https://github.com/JosssphZhou/poki/issues/59">#59</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=240" width="120" height="120" alt="igc110"/><br /><sub><b>igc110</b></sub></a><br />Found why taps on a physical iPhone were slow in <a href="https://github.com/JosssphZhou/poki/issues/10">#10</a>; the fix that followed made them about a third faster.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=240" width="120" height="120" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a><br />Ported Poki to Linux and tested it on a physical iPhone over USB, LAN and Tailscale in <a href="https://github.com/JosssphZhou/poki/issues/16">#16</a>; the README now points to it.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=240" width="120" height="120" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a><br />Traced failing touches on a physical iPhone to a missing display service in <a href="https://github.com/JosssphZhou/poki/issues/18">#18</a>; Poki now says nothing was sent and points to prepare-device.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=240" width="120" height="120" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a><br />Fixed a corrupt cached route that aborted unrelated Agent tasks (<a href="https://github.com/JosssphZhou/poki/issues/21">#21</a>, <a href="https://github.com/JosssphZhou/poki/pull/22">#22</a>), then let the Agent reuse its post-action screen read in <a href="https://github.com/JosssphZhou/poki/pull/37">#37</a>.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=240" width="120" height="120" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a><br />Reported in <a href="https://github.com/JosssphZhou/poki/issues/25">#25</a> that a natural-language stop request did not interrupt an iMessage task; Poki now replies to mid-task messages and points to /stop.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=240" width="120" height="120" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a><br />Reproduced two Agent bugs in <a href="https://github.com/JosssphZhou/poki/issues/27">#27</a> and <a href="https://github.com/JosssphZhou/poki/issues/28">#28</a>, then merged seven fixes and test repairs, from cancelled input locks (<a href="https://github.com/JosssphZhou/poki/pull/102">#102</a>) to invalid touch coordinates (<a href="https://github.com/JosssphZhou/poki/pull/136">#136</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=240" width="120" height="120" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a><br />Fixed in <a href="https://github.com/JosssphZhou/poki/pull/34">#34</a> a RemotePairing connection that died when the iPhone's LAN address changed (<a href="https://github.com/JosssphZhou/poki/issues/30">#30</a>); a real iPhone reconnected in 768 ms.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=240" width="120" height="120" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a><br />Field-tested the iPhone app over cellular and from Windows in <a href="https://github.com/JosssphZhou/poki/issues/35">#35</a> and <a href="https://github.com/JosssphZhou/poki/issues/40">#40</a>, which led to the Wi-Fi setup note (<a href="https://github.com/JosssphZhou/poki/issues/138">#138</a>); reported <a href="https://github.com/JosssphZhou/poki/issues/162">#162</a>.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=240" width="120" height="120" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a><br />Fixed taps that failed every time over RemotePairing from a Windows host in <a href="https://github.com/JosssphZhou/poki/pull/39">#39</a>; 5 of 5 taps then worked.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=240" width="120" height="120" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a><br />Ran an insurance-terms check on a real iPhone over Tailscale in <a href="https://github.com/JosssphZhou/poki/issues/42">#42</a>; the report shaped clearer USB errors and a per-session transport switch.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=240" width="120" height="120" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a><br />Recorded demo videos of Poki driving a real iPhone, so new visitors can see what it does before installing anything.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=240" width="120" height="120" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a><br />Added OpenCode Go as a model account in the iPhone app in <a href="https://github.com/JosssphZhou/poki/pull/68">#68</a>, with its own Keychain credential and independent model choice.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=240" width="120" height="120" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a><br />Posted a full timeline of Runner pairing failing after 25 idle minutes in <a href="https://github.com/JosssphZhou/poki/issues/69">#69</a>; Setup now points to Loopback and Pairing (<a href="https://github.com/JosssphZhou/poki/issues/70">#70</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=240" width="120" height="120" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a><br />Made batch calls report an ambiguous device instead of crashing (<a href="https://github.com/JosssphZhou/poki/pull/74">#74</a>), added POKI_MCP_DEVICE (<a href="https://github.com/JosssphZhou/poki/pull/75">#75</a>) and an optional per-task approval gate (<a href="https://github.com/JosssphZhou/poki/pull/77">#77</a>).</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=240" width="120" height="120" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a><br />Fixed pairing setup sending people to the wrong Settings page, so the Developer Mode and UI Automation steps now open the right one (<a href="https://github.com/JosssphZhou/poki/pull/137">#137</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=240" width="120" height="120" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a><br />Fixed screen reads that ran past their call deadline in <a href="https://github.com/JosssphZhou/poki/pull/139">#139</a>, with a regression test for consistently slow runner responses.</td>
    </tr>
  </tbody>
</table>
<!-- CORE-CONTRIBUTORS:END -->

## Special contributors

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=240" width="120" height="120" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a><br />Sent a full set of interface designs for the 0.4.0 redesign, from the chat and Live Activity to Settings and a first run (<a href="https://github.com/JosssphZhou/poki/pull/250">#250</a>, <a href="https://github.com/JosssphZhou/poki/pull/256">#256</a> to <a href="https://github.com/JosssphZhou/poki/pull/268">#268</a>); they shaped the direction of the new interface.</td>
    </tr>
  </tbody>
</table>

## Thanks

Thanks to everyone who opened an issue or pull request. Your feedback and fixes make Poki better.

<!-- THANKS-WALL:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=160" width="80" height="80" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=160" width="80" height="80" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=160" width="80" height="80" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=160" width="80" height="80" alt="edge369"/><br /><sub><b>edge369</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=160" width="80" height="80" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=160" width="80" height="80" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=160" width="80" height="80" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=160" width="80" height="80" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/htx996"><img src="https://avatars.githubusercontent.com/u/95217139?v=4&size=160" width="80" height="80" alt="htx996"/><br /><sub><b>htx996</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=160" width="80" height="80" alt="igc110"/><br /><sub><b>igc110</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/iTry"><img src="https://avatars.githubusercontent.com/u/1381960?v=4&size=160" width="80" height="80" alt="iTry"/><br /><sub><b>iTry</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=160" width="80" height="80" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/kilingzhang"><img src="https://avatars.githubusercontent.com/u/17439300?v=4&size=160" width="80" height="80" alt="kilingzhang"/><br /><sub><b>kilingzhang</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=160" width="80" height="80" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/lunar-me"><img src="https://avatars.githubusercontent.com/u/275556969?v=4&size=160" width="80" height="80" alt="lunar-me"/><br /><sub><b>lunar-me</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=160" width="80" height="80" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=160" width="80" height="80" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/oasis979559-alt"><img src="https://avatars.githubusercontent.com/u/295108220?v=4&size=160" width="80" height="80" alt="oasis979559-alt"/><br /><sub><b>oasis979559-alt</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=160" width="80" height="80" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=160" width="80" height="80" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=160" width="80" height="80" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=160" width="80" height="80" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=160" width="80" height="80" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/wanghao-SunSky"><img src="https://avatars.githubusercontent.com/u/73684879?v=4&size=160" width="80" height="80" alt="wanghao-SunSky"/><br /><sub><b>wanghao-SunSky</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/windywendyday"><img src="https://avatars.githubusercontent.com/u/65647922?v=4&size=160" width="80" height="80" alt="windywendyday"/><br /><sub><b>windywendyday</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=160" width="80" height="80" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=160" width="80" height="80" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zcyoung2000"><img src="https://avatars.githubusercontent.com/u/62181891?v=4&size=160" width="80" height="80" alt="zcyoung2000"/><br /><sub><b>zcyoung2000</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=160" width="80" height="80" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zqy5608"><img src="https://avatars.githubusercontent.com/u/14949471?v=4&size=160" width="80" height="80" alt="zqy5608"/><br /><sub><b>zqy5608</b></sub></a></td>
    </tr>
  </tbody>
</table>
<!-- THANKS-WALL:END -->

## Poki MCP (earlier computer connection, no longer updated)

Poki MCP is the earlier way to use Poki: an agent on your Mac, such as Claude Code or Codex, drives an iPhone or the iOS Simulator, and Poki Agent, a terminal agent with iMessage and Telegram channels, runs on it. It is no longer updated and stays here as it is for people who already use it or want to build on it. For a maintained way to run Poki, [install the Poki app](#install-poki-on-your-iphone) on your iPhone.

**Let your agent install it.** Copy this to your agent:

```text
Install https://github.com/JosssphZhou/poki following its root AGENTS.md, including the MCP skill, and stop whenever you need me to act.
```

**Poki MCP.** Already using Claude Code, Codex, or another MCP client? Connect Poki MCP and use your own subscription. No extra model account needed.

Start the server and keep it running:

```sh
git clone https://github.com/JosssphZhou/poki.git
cd poki
./bin/setup
npm start
```

Poki MCP builds from source, so it has its own requirements: macOS 15 or later, full Xcode, Rust, Node.js 24+, Python 3, and ffmpeg. The Poki app does not need Xcode. `./bin/setup` checks for missing dependencies. The initial build takes a few minutes.

Poki targets macOS. For Linux, see the community port [poki-for-linux](https://github.com/carrotciallo/poki-for-linux) ([#16](https://github.com/JosssphZhou/poki/issues/16)), maintained outside this repo.

Poki MCP on Windows: community port at [scy7796/poki-for-windows](https://github.com/scy7796/poki-for-windows) (maintained by its author, not tested by us).

### Prebuilt macOS arm64 package

Download `poki-v0.1.1-macos-arm64.tar.gz` from the [Poki MCP v0.1.1 release](https://github.com/JosssphZhou/poki/releases/tag/v0.1.1) and run:

```sh
tar -xzf poki-v0.1.1-macos-arm64.tar.gz
cd poki-v0.1.1
npm ci --no-audit --no-fund
npm start
```

Poki MCP releases are tagged `vX.Y.Z`. The iPhone app's `app-` releases do not carry this package. The package includes the native bridge and idevice tools. You do not need Rust or `./bin/setup`. You still need macOS on Apple Silicon, full Xcode, Node.js 24+, Python 3, and ffmpeg. Register your MCP client and install the optional Agent as described below.

In another terminal, from the same directory, register the MCP server:

```sh
claude mcp add --scope user poki-mcp -- node "$PWD/src/stdio.mjs"   # Claude Code
codex mcp add poki-mcp -- node "$PWD/src/stdio.mjs"                 # Codex
```

**Poki Agent.** For Poki's standalone terminal agent or messaging channels, keep `npm start` running and open another terminal in the same directory. Install the agent, add its command to this terminal's path, and sign in:

```sh
npm ci --prefix agent
export PATH="$PWD/bin:$PATH"
poki login
poki status
```

Poki Agent uses GPT-6.1 Terra (`gpt-6.1-terra`) with low reasoning by default. We recommend keeping it: it is the fastest setup we have tested for phone tasks. Override it with `POKI_AGENT_MODEL`; see [Run Poki Agent](agent/README.md).

For a physical iPhone, pair it with your Mac over USB first. See [Physical iPhone setup](docs/physical-iphone.md).

`./bin/poki update` still pulls the newest `main` and rebuilds. See [Update](AGENTS.md#update) for the restart steps and the optional update check.

### Try a task with Poki Agent

With Poki Agent, one connected iPhone is selected automatically. With multiple devices, add `--device '<device UUID>'`.

```sh
node bin/call.mjs list_devices   # Find your device UUID
poki "Search esp32 in Chrome and summarize the top result"
```

> **Note:** Poki controls your real iPhone. If you ask it to send messages or make payments, it will. Screen contents are sent to your configured model service.

Gets faster with use: Poki Agent remembers past tasks and runs them faster on repeat.

**Channels:** After configuring an authorized channel, start it with `poki imessage` or [`poki telegram`](agent/README.md#telegram). See [Poki Agent](agent/README.md) for setup.

**MCP clients:** Claude Code, Codex, and any client supporting `mcpServers` JSON.

On physical devices, app container export and direct links to Settings subpages are unavailable. See [verification and known limits](docs/verification.md).

## Disclaimer

Poki is an independent open source project. It is not affiliated with, or endorsed by, Apple, OpenAI, or the makers of any app or website it operates. iPhone is a trademark of Apple Inc.

Automating third-party apps and websites may violate their terms of service. Decide for yourself whether to use Poki with a given service. You are responsible for what it does on your device and accounts, including messages it sends, changes it makes, and any account restrictions that result.

Poki is provided "as is", without warranty, as set out in the AGPL-3.0 license.

## License

Poki's code is open source under the [AGPL-3.0-only license](LICENSE).

The Poki bear, the app icon and Poki's other artwork are not covered by that license. You can use screenshots to write about Poki; a fork needs its own name and artwork. See [BRAND.md](BRAND.md).

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. Open-source dependencies and third-party assets retain their respective licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). To contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgments

<p align="center">
  <img src="docs/images/acknowledgments.png" width="860" alt="Built on open source: pi, idevice, idb, BlueBubbles, Hermes Agent, MCP SDK, sharp, and FFmpeg"><br>
  <sub>Open source acknowledgments: <a href="https://github.com/earendil-works/pi">pi</a> | <a href="https://github.com/jkcoxson/idevice">idevice</a> | <a href="https://github.com/facebook/idb">idb</a> | <a href="https://github.com/BlueBubblesApp/bluebubbles-server">BlueBubbles</a> | <a href="https://github.com/NousResearch/hermes-agent">Hermes Agent</a> | <a href="https://github.com/modelcontextprotocol/typescript-sdk">MCP SDK</a> | <a href="https://github.com/lovell/sharp">sharp</a> | <a href="https://github.com/FFmpeg/FFmpeg">FFmpeg</a></sub>
</p>

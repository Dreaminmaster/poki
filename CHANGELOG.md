# Changelog

All notable user-visible changes to Poki, Poki Setup, and Poki MCP are documented in this file.
Working notes per round stay in `native/ios-app/CHANGELOG-round.md`; each promotion release
verifies and publishes its section from this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Build numbers correspond to the GitHub Actions run number or commit count of the release build.

## [Unreleased]

## [0.5.1-beta.1] - 2026-11-26

Build 2912.

### Added
- Redesigned step-by-step guided setup from Loopback (with installed proxy app detection and free LocalDevVPN from the App Store) through the Poki Loopback Shortcut, background location setup, and model accounts, paired with a unified Setup page and Guide Me walkthrough. Thanks to @ZhehanZhang (#649).
- Post-setup **Keep Poki Opening** Apple Account sign-in prompt for free 7-day signing installs, pre-filling the Apple Account from Poki Setup so Poki can renew itself automatically on your iPhone. Thanks to @ZhehanZhang (#744).
- Remote MCP **Connectors** (`Settings > Connectors`) with built-in presets for Notion, Linear, GitHub, Atlassian, Asana, Canva, Stripe, and Hugging Face, plus two-step **Add Custom Connector** setup with live server checks, multi-account support, per-account approval modes, and per-tool toggles. Thanks to @ZhehanZhang (#649, #652).
- **Senses** and always-on **Screen History** with a direct timeline view, soft-zoom transitions, automatic developer disk image remounting after reboot, the Poki Loopback Shortcut reconnect action, provisional habit memories, personalized home suggestions, and structured Screen History share cards when answers are shared with your chat model. Thanks to @ZhehanZhang (#649, #652).
- On-device **Local Models** (`Settings > Models > Local`) supporting Apple Intelligence and downloadable 4-bit MLX models (Qwen 3 1.7B and Qwen 3.5 2B on iPhones with 6 GB RAM or more), unified per-use model pickers (**Chat**, **Voice**, **Decisions**, **Senses**), and fast decision models (**Quick Fixes**) that help skills and one-call action paths recover from unexpected screens. Thanks to @ZhehanZhang (#649).
- Active model button under the message composer while writing, opening a native sheet to switch models and approval modes without losing your draft, with a matching one-row preview in `Settings > Input Field` when turned off. Thanks to @ZhehanZhang and @ScottH1122 (#758, #760).
- Built-in support for GPT-6.2 Sol and GPT-6.2 Astra across OpenAI, ChatGPT, and OpenRouter (with PiSwift v1.6.0), automatic 24-hour model list refreshes with failure backoff, and ChatGPT plan model discovery. Thanks to @ZhehanZhang (#755, #761, #765).
- One-time "Tap Poki" discovery tip on the home screen bear and a menu chevron on the conversation Poki pill so model and approval controls are easier to find. Thanks to @ZhehanZhang (#747).
- Direct local MCP connections over USB or Wi-Fi (with relay fallback), per-computer access switches in `Settings > External Connections > Computers`, simulator MCP serving (`poki-setup mcp serve --simulator`), and PokiCore element state reporting, slider adjustments, and screenshot sizing options. Thanks to @ZhehanZhang (#649).
- Siri AI tool support for **Send Task to Poki**, **Talk to Poki**, and **Poki Anytime** on iOS 27.3 or later, and **Get Debug Bundle** in `Settings > Advanced` to export a redacted diagnostic archive. Thanks to @ZhehanZhang (#649).
- Close the ChatGPT sign-in sheet automatically once the local loopback callback completes, with a native progress indicator while signing in. Thanks to @ZhehanZhang (#769).

### Changed
- Reorganized Settings into **How Poki Works**, **Safety and Access** (grouping Approvals, Screen History, Activity Log, Face ID & Passcode, and External Connections), and **This App**, replacing Poki's separate PIN with system Face ID, Touch ID, and Passcode, replacing the 4-segment sensitivity control with a slider, and hiding the Ready Live Activity by default. Thanks to @ZhehanZhang (#649, #653).
- Switched the Poki app typeface to Allo, added a layered dark launch screen, unified chat bubble and task card surfaces, organized Memory into dedicated per-area pages with an in-page ask bar, and simplified the bear wardrobe onto one page with consistent tile sizes. Thanks to @ZhehanZhang (#649, #651).
- Refined the message composer with evenly padded app capsules, native rounded mention row highlights, apps listed first in the `+` sheet (dropping duplicate Model and Approvals rows), and home suggestion pills that animate smoothly with the keyboard. Thanks to @ZhehanZhang (#651, #653).
- Reduced Screen History overhead by moving JSON processing off the main thread and skipping accessibility reads on unchanged screens for up to 30 minutes. Thanks to @ZhehanZhang (#650, #731).
- Display mounted developer disk image readiness and errors on the Loopback detail page when local automation is already ready. Thanks to @ScottH1122 (#522).
- Adopted the full Contributor Covenant 3.0 alongside concise six-language community rules in `CODE_OF_CONDUCT.md` (#618, #683 thanks to @ZhehanZhang).

### Fixed
- Keep `SettingsRow` leading titles intact and truncate long trailing values (such as custom provider-prefixed model names) on one line, while letting warning and action labels wrap cleanly at accessibility Dynamic Type sizes (#787).
- Open target apps beside Poki during iPhone Duo Split View tasks and harden folded Duo cover display launching, compatibility-window normalization, and display confirmation (#607, #728).
- Synchronize ChatGPT Live Voice completion replies with in-flight phone actions so Poki waits until tools and turns finish before speaking completion (#730).
- Close automation sessions that finish opening after a close or Stop request was already sent, preventing the iOS "Automation Running" watermark from staying stuck on screen. Thanks to @ZhehanZhang (#743).
- Retry Apple Account sign-in automatically after error `-22411` with loop protection and update fallback anisette servers (`new.ani.sidestore.io`, `mac-ani.jkcoxson.com`, `ani.iloader.app`, `ani3.stikstore.app`). Thanks to @ZhehanZhang (#742).
- Size the `@` app mention picker to match its visible results instead of stretching to full height for short lists. Thanks to @creamtea47 (#763).
- Register iPhones with blank device names in Poki Setup by falling back to `iOS Device`. Thanks to @kongyanye (#762).
- Reuse the pairing record accepted by the iPhone across every USB setup step in Poki Setup. Thanks to @ZhehanZhang (#757).
- Validate result card actions for every selectable item, clear navigation state when the built-in browser stops, compact oversized Live Activity payloads by UTF-8 byte budget, share concurrent installed-app refreshes, and retry Bonjour pairing searches after network path changes. Thanks to @ScottH1122 (#706, #711, #712, #713, #720).
- Fix local model downloads stalling at 99%, preserve chat memory attribution and atomic saves for successful tasks, improve Pinyin mention composition, and prevent action paths from sending input into Poki. Thanks to @ZhehanZhang (#649).

### Security
- Keep captured screen text out of online Home follow-up prompts when Insights uses an online Chat Model, sending only screen titles, app names, and timestamps, and bind prompt creation and delivery to the same model setting. Thanks to @ZhehanZhang (#788).
- Check both the shared summary and raw local model answer before sharing Screen History context with Poki's chat model or external agents, and fail closed in the agent unlock helper unless the iOS lock screen is confirmed. Thanks to @ZhehanZhang (#649, #652).
- Strip PiSwift v1.6.0's renamed `session-id` header during failover to third-party custom backup endpoints so official endpoint sessions are never forwarded. Thanks to @ZhehanZhang (#765).

## [0.5.0-beta.1] - 2026-11-24

Build 2500. Includes Poki Setup 0.2.9.

### Added
- Rebuilt Live Voice with faster push-to-talk, a ready chime on connection, more reliable background voice, and mid-call voice commands ("Stop" to cancel the current task, "Quiet" to pause voice playback) (#659, #660).
- Watch videos and ask Live Voice questions interactively while screen sharing on iOS 27 or later (#599).
- Direct ChatGPT account sign-in for text chat and Live Voice with no manual API key setup required (#682).
- Visual result cards and transit transfer cards with item image previews for Trip.com, Taobao, Dianping, Uber Eats, and 12306 (#575, #669). Thanks to @ZhehanZhang.
- Quick App Picker in the input bar: type `@` to autocomplete a target app, or tap `+` to choose from frequent apps or the full app list (#723). Thanks to @ZhehanZhang.
- Native bear avatar menu on the home screen to switch models and approval methods quickly, plus a post-update What's New card (#680, #723). Thanks to @ZhehanZhang.
- Task cards show which memories and skills were reused in each run while Poki continues learning habits from successful tasks (#553, #578).
- Full-text search across all saved conversations with direct jump-to-message navigation, refined Memory Source browsing, and more accurate multi-task session switching and approval attribution. Thanks to @Dreaminmaster (#249, #322).
- Local proxy detection for `10.7.0.1` (such as Karing) with clear loopback setup guidance, stepping aside automatically when an external proxy is already handling local connections (#671). Thanks to @ZhehanZhang.
- Dynamic Type support on the bear customization screen. Thanks to @ScottH1122 (#630).

### Changed
- Significantly faster phone operations across everyday tasks, more accurate long-list browsing without skipping or repeating items, and clearer paragraph formatting in replies (#560, #585, #602, #606, #647, #668).
- Refreshed first-time onboarding guidance with cleaner setup steps (#678).
- Tapping the Dynamic Island or Live Activity during an active task returns directly to the target app without dropping the session, and home screen browsing is smoother (#679, #687).
- Poki Setup 0.2.9 compares Poki app versions before build numbers so lower-build releases update cleanly (#634, #722).

### Fixed
- Release the microphone immediately when a voice call ends so Poki does not interrupt audio in other apps (#581).
- Stabilize floating confirmation popovers on iPad, allow selecting and copying browser prompt text, and resolve iPhone Duo cover display for compatibility apps (#582, #675).
- Recover automatically when a local loopback connection fails during the opening handshake. Thanks to @ScottH1122 (#644).
- Fix stability issues across voice dictation, Live Activities, built-in browser handoffs, conversation archive migration and saving, and network reconnection. Thanks to @ScottH1122 (#692 to #705, #707 to #710).
- Put pairing guidance ahead of developer disk image recovery and clear stale screenshots across task boundaries (#571, #677).

### Security
- Strengthen prompt content isolation so on-screen and web text is treated strictly as data rather than instructions, keep desktop pairing credentials private from creation, and ask for confirmation before a link modifies relay or pairing settings. Thanks to @Joaov41 (#535), and #570.

## [0.4.7-beta.1] - 2026-11-21

Build 9971. Hotfix built directly on 0.4.6 Beta 1.

### Changed
- Redesigned the Poki bear wardrobe with native iOS components and interactions, consolidating all customization options onto one page. Thanks to @ScottH1122 (#586), and #596.

### Fixed
- Fix a launch crash on devices such as iPhone 17 Pro by waiting for the first frame to render before loading Liquid Glass effects (#587, reported in #554).
- Stop browsing and swiping in Photos from triggering false payment approval prompts (#576).
- Keep pending Dynamic Island approval actions interactive after the island collapses (#594).
- Launch the installed WeChat edition directly without an extra 3-second delay, exclude typed text from path summaries, launch apps whose names contain periods, and report the last completed step when an action chain stops early (#565).

## [0.4.6-beta.1] - 2026-11-20

Build 1922. Includes Poki Setup 0.2.5 through 0.2.8.

### Added
- Search for and launch any installed app by name with real app names and icons (#331, thanks to @ZhehanZhang), recognize short app names such as NetEase Cloud Music (#449, thanks to @ScottH1122), and open named WeChat mini programs directly (#448, thanks to @ScottH1122).
- "Poki Anytime" voice from the iPhone Action Button, Shortcuts, or Siri without leaving your current app (#477, #497).
- Live voice reads the current screen, opens apps by name, and matches Poki's interface language with shorter first replies (#498).
- Preview launch screen and customizable outfits for the Poki bear (#520, #536, #543, #552).
- Multiple OpenAI-compatible custom model providers with per-provider Responses API or Chat Completions support and fallback addresses (#566, thanks to @ZhehanZhang), plus direct model list discovery before saving (#458, thanks to @creamtea47).
- Reorganized Memory page grouped by app with a global "About You", editable and lockable entries, undo, and "Recent Updates" (#505).
- Cellular Startup item in Connection Check (#512, thanks to @xiaweiyi713).
- Safety confirmations for sensitive taps in Poki's built-in browser while limiting navigation to public web pages (#351, thanks to @ZhehanZhang).
- Poki Setup 0.2.5 to 0.2.8: new Devices page with official iPad support, single install progress bar, automatic Windows Apple driver guide (#379, #509, thanks to @ZhehanZhang), Simplified Chinese desktop interface (#507, thanks to @creamtea47), and standalone Setup update mirroring (#563).
- Poki MCP: support approved clipboard reads over RemotePairing (#459, thanks to @soloface).

### Changed
- Rewrote built-in system prompts for a more concise, decisive iPhone-first personal assistant (#479).
- Faster multi-screen actions in a single call with settled screen reads (#490, thanks to @ZhehanZhang).
- Rename "Routines" to "Skills" and file each skill under the last app it operates (#518, #538).
- Center the home page, narrow the sidebar, and fill both displays in iPhone Duo Split View (#439, #545, #564, thanks to @ZhehanZhang).
- Restyle Settings > Signing & Updates to match other settings pages, with expired Apple sign-in prompts and HTTP 503 guidance (#483, #500, #527, #539, thanks to @ZhehanZhang).
- Show task completion only through the Dynamic Island on models that support it, avoiding duplicate notification banners (#420).
- Align Chinese UI terminology across the app (#482, #559), default live voice transcription to Chinese (#537), and keep Screen History behind an experimental setting with privacy disclosures (#435, #446, #523, #567, thanks to @Dreaminmaster).

### Fixed
- Lock screenshots, taps, and screen reads to the active panel in iPhone Duo Split View across folding, unfolding, and rotation, and keep running tasks on their original panel (#76, #474, #548, #558, thanks to @kira-ariaki, @bwjoke, and @zqy5608).
- Announce "Done" only once when a task ends, keep the End button and bear inside the expanded Dynamic Island (#496, #508), and use smaller bear icons in compact Live Activities to fix the gray block on Apple Watch (#457, thanks to @creamtea47).
- Poki Setup: smooth Apple sign-in two-factor flows (#450, #485, #494, #499), fix HTTP 503 errors from Apple sign-in (#549, #557, thanks to @lekt9), and end background helper processes cleanly when quitting (#502).
- Custom model gateway fixes: parse doubled `data:` SSE prefixes (#348, thanks to @ZhehanZhang), apply updated service addresses immediately in open chats (#428, thanks to @ScottH1122), and send the expected header in OpenCode connection tests (#427, thanks to @ScottH1122).
- Show "Stopped" consistently for cancelled tasks (#556), resume waiting tasks automatically after automation permission is granted (#546), dismiss the keyboard on empty-space taps without shifting the composer (#501), leave archived or deleted conversations right away (#468, thanks to @ZhehanZhang), refresh home shortcuts dynamically with content and language changes (#425, #453, thanks to @ScottH1122), use the system proxy for developer disk image downloads (#444), and report unchanged screen taps as unconfirmed (#452, thanks to @ScottH1122).
- Poki MCP: end a running Poki before `install_app` so updates do not stall (#503), and release the iPhone camera and microphone when input is idle (#239, thanks to @logicrw).

## [0.4.5-beta.1] - 2026-11-19

Build 1800. Hotfix built on 0.4.4 Beta 1 with Apple sign-in fixes.

### Fixed
- Request at most one two-factor verification code per Apple Account sign-in and stop cleanly on rate limits (#450).
- Complete sign-in after entering the verification code and stop misclassifying HTTP 401 (`-22411`) as a rate limit (#494).

## [0.4.4-beta.1] - 2026-11-17

Build 1683.

### Fixed
- Keep your Apple Account signed in across updates in Poki Setup and on iPhone by refreshing the Mac client identity, migrating saved keychain entries, and prompting directly for a six-digit verification code when needed (#433).
- Fix a launch timeout crash on startup and upgrades by moving developer disk image checks, developer framework loading, and conversation history loading and archiving off the main thread (#434).
- Allow Apple Account sign-in to continue when Apple asks to repair the account, or direct you to `account.apple.com` when account setup is required. Thanks to @ZhehanZhang (#440).
- Mount the personalized developer disk image on iPhones running iOS versions earlier than 26.4, including iOS 18, instead of failing in Preparing. Thanks to @ZhehanZhang (#441).

## [0.4.3-beta.1] - 2026-11-16

Build 1670. Includes Poki Setup 0.2.4.

### Added
- Screen History (experimental, off by default in Settings > Advanced > Testing Options): reads the front app only when started, stays on your iPhone behind a PIN lock, and can be cleared at any time (#360, #415, thanks to @ZhehanZhang).
- Say "continue" to pick up a stopped task, restoring saved conversation context within a bounded budget and asking which task you mean when more than one exists (#333, #364, thanks to @Dreaminmaster).
- Add "Don't ask again" to approval cards and default approval mode to Never Ask (#412).
- End tasks automatically when they stop making progress instead of at a fixed 60-step limit (#414).
- New done-state artwork for the happy Poki bear (#422).

### Changed
- Consecutive actions from the same assistant continue in one conversation while keeping overlapping sessions isolated (#337, #339, thanks to @Dreaminmaster).
- Approving on the Dynamic Island no longer bounces through Poki. Thanks to @ZhehanZhang (#367).
- Keep the automation session between tasks on iOS 18 to 26 so iOS no longer asks for your passcode each time (#413).
- Report the installed iPhone app build in relay hello messages. Thanks to @ScottH1122 (#390).

### Fixed
- Stop showing a false Local Connection prompt when switching from Wi-Fi to cellular (#410).
- Keep authentication request bodies out of trace logs (#193), validate paste targets before changing field contents (#199), and release the microphone when voice startup stalls (#202).
- Keep receipts for completed steps when the final screen read fails (#232), stop chained phone actions when input arrival is unconfirmed (#234), and drop stale element references when switching iPhones (#235). Thanks to @Dreaminmaster.
- Keep automation open until Poki finishes returning after idle (#396) and stop requiring Live Activities for background setup (#402). Thanks to @mac8005.
- Poki Setup 0.2.4: wait for Apple's automatically pushed six-digit verification code and request one only if none arrives. Thanks to @ZhehanZhang (#403), and #405.

## [0.4.2-beta.2] - 2026-11-16

Build 1515. Updates Poki Setup only; the iPhone app build is identical to 0.4.2 Beta 1.

### Fixed
- Poki Setup 0.2.4 for Mac and Windows: wait for the six-digit verification code Apple sends to your devices automatically, and request one only if none arrives. Thanks to @ZhehanZhang (#403), and #405.

## [0.4.2-beta.1] - 2026-11-15

Build 1515. Includes Poki Setup 0.2.3.

### Added
- Settings > Interface Size: follow the system text size, or choose from seven standard and five accessibility sizes for chat and Settings with a live preview. Thanks to @ScottH1122 (#284).
- Attach JSON, Markdown, and plain text files up to 100 KB each in chat, view the full text, and keep attachments when retrying a message. Thanks to @ScottH1122 (#370).
- Two-app side-by-side workspaces on iPhone Duo that wait on rotation, keep Stop available, resume once the same layout returns, and preserve conversations and unsent drafts across screen widths. Thanks to @Ryanwu316 (#354).
- Poki Setup 0.2.3 runs natively on both Intel Macs and Apple silicon (#365) and is signed by a new Developer ID team accepted by the installer (#381).

### Changed
- Show the "Automation Running" watermark only while Poki is operating your phone by opening the automation session on demand and closing it when the task ends. Thanks to @ZhehanZhang (#357).
- Prefer USB when the same iPhone is connected to Poki Setup over both USB and Wi-Fi. Thanks to @ScottH1122 (#209).

### Fixed
- Show the passcode explanation with Continue and Cancel in Settings > Connection if the alert does not appear (#378), explain why unavailable developer tools failed with recovery steps, and present automation prompts over Settings (#368).
- Show failed phone connections during developer disk image mounting as Stopped with the reason instead of waiting for the network. Thanks to @ScottH1122 (#371).
- Keep the default message field on one line when focused, keep stopped task results in their original conversation (#253), stop Poki's chat when an external agent cancels a delegated task (#252), and show a Live Activity when returning to Poki for a task started in the background (#374). Thanks to @ScottH1122.
- Fix Apple Account sign-in failing with "A Mac with macOS version 10.13 or later is required" and skip unresponsive anisette servers in Poki Setup 0.2.3 (#309).

### Security
- Require approval for buttons whose sensitive word appears late in a long label and recognize Traditional Chinese sensitive terms. Thanks to @ScottH1122 (#372).
- Require on-iPhone owner consent before authorizing any new connection through the relay. Thanks to @ScottH1122 (#373).

## [0.4.1-beta.1] - 2026-11-14

Build 1382.

### Added
- Choose Follow System, English, Simplified Chinese, or Traditional Chinese in Settings so the interface and home screen task text follow the selected language (#294, and #248 thanks to @ScottH1122).
- Home screen "Star Poki on GitHub" pill that uses the GitHub app, prompts installation if missing, and hands sign-in back to you when signed out (#312, #318).

### Changed
- Consolidate onto a single Beta update channel backed by a signed R2 catalog with automatic GitHub fallback (#319).
- Clarify what full iOS screen reads return (#295, thanks to @ScottH1122) and move release notes to `CHANGELOG.md` (#313).

### Fixed
- Explain how to close and reopen Poki if an in-app update stalls during system installation (in English, Simplified Chinese, and Traditional Chinese) and exit cleanly after update confirmation (#324, #325, #327, #332).
- Fix a launch crash when creating the home screen bear mesh. Thanks to @whiteluw (#326).
- Let the status bar follow the system light or dark appearance. Thanks to @ZhehanZhang (#346).
- Avoid attributing failed screen reads to the previously opened app (#358), use accurate app bundle identifiers with Home Screen search fallback (#355), hide the chat vertical scroll bar and show the reason under the Automation switch when it cannot turn on (#315), fix the built-in browser hanging after close and reopen (#323), and avoid routing relay requests over closing sockets (#316).

## [0.4.0-beta.1] - 2026-11-13

Build 1260. Replaces the entire iPhone app interface; on first launch after upgrading from 0.3.1, existing conversations move to Archived Conversations in Settings.

### Added
- Conversation-style home page with Poki's 3D bear greeting you by time of day and reacting to task state, everyday app rows sorted by usage and routines, an app-icon conversation drawer, conversation archiving and search, inline app capsules, a bear status card, top setup-issue banners, dark mode, and light/dark/tinted app icons.
- One-tap spoken voice conversations that continue in the background with Dynamic Island status, plus dictation, photo/camera/PDF attachments, and streaming Markdown rendering for headings, lists, tables, quotes, and code.
- Built-in sandboxed browser for web lookups with persistent logins, owner takeover for logins and captchas, and automatic dismissal of cookie and privacy banners.
- One-sentence sensitive action approvals across chat, Dynamic Island, Lock Screen, and notifications with three approval modes and four sensitivity levels, plus live step progress in the Dynamic Island and Live Activities.
- System entry points via the iPhone Action Button, Control Center, Lock Screen controls, Shortcuts, and Siri.
- First-launch onboarding, model Test Connection checks, cellular startup when the developer disk image is mounted, automatic pairing-port recovery, and an update-only Poki Setup command on Mac.

### Changed
- Regrouped Settings into Connection, Models, Dictation and Mute, Approvals, Agents, Memory, Archived Conversations, Signing & Updates, Notifications, Appearance, and Advanced.
- Faster task stops, pre-send message readback verification, and clearer post-update restart guidance.

## [0.1.1] - 2026-11-06

### Added
- Remote connections for Poki MCP, building on the proposal and testing by @ZhehanZhang (#2).
- Daily anonymous update notices in `poki_mcp_status` and `poki status` (can be disabled with `POKI_NO_UPDATE_CHECK=1`).
- `poki update` command for clean `main` source checkouts, plus restart prompts when running an older version after updating.

### Fixed
- Shut down iMessage and Telegram channel processes cleanly and remove their lock files when the parent process exits. Thanks to @edge369 (#3).

## [0.1.0] - 2026-11-05

### Added
- First public release of Poki MCP, a local MCP server allowing Claude Code, Codex, or other MCP clients to read and operate a real iPhone with no jailbreak or extra hardware.
- Poki Agent for sending iPhone tasks from iMessage, Telegram, or the terminal with reusable route learning.
- Initial standalone iOS app prototype with loopback pairing, relay support (`deploy/cf-relay/deploy.sh`), and Lock Screen approval before sensitive actions.

[Unreleased]: https://github.com/JosssphZhou/poki/compare/app-0.5.1-beta.1...HEAD
[0.5.1-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.5.0-beta.1...app-0.5.1-beta.1
[0.5.0-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.4.7-beta.1...app-0.5.0-beta.1
[0.4.7-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.4.6-beta.1...app-0.4.7-beta.1
[0.4.6-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.4.5-beta.1...app-0.4.6-beta.1
[0.4.5-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.4.4-beta.1...app-0.4.5-beta.1
[0.4.4-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.4.3-beta.1...app-0.4.4-beta.1
[0.4.3-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.4.2-beta.2...app-0.4.3-beta.1
[0.4.2-beta.2]: https://github.com/JosssphZhou/poki/compare/app-0.4.2-beta.1...app-0.4.2-beta.2
[0.4.2-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.4.1-beta.1...app-0.4.2-beta.1
[0.4.1-beta.1]: https://github.com/JosssphZhou/poki/compare/app-0.4.0-beta.1...app-0.4.1-beta.1
[0.4.0-beta.1]: https://github.com/JosssphZhou/poki/releases/tag/app-0.4.0-beta.1
[0.1.1]: https://github.com/JosssphZhou/poki/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/JosssphZhou/poki/releases/tag/v0.1.0

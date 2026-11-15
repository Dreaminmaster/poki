# Changelog

Poki and Poki Runner ship together under one version. Each entry says what changed for the person
using the phone, then what changed underneath. The working notes per round stay in
native/ios-app/CHANGELOG-round.md; this file is what goes into a release and the AltStore source.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).
Build numbers are the GitHub Actions run number of the release workflow.

## [0.4.2] - Unreleased

### Automation
- The "Automation Running" watermark now shows only while Poki is operating your phone, and goes away when the task ends. Poki opens its automation session when a task needs the phone and closes it when the work is done. Thanks to @ZhehanZhang (#357).
- If the passcode explanation does not appear when you turn on automation, Settings > Connection shows it with Continue and Cancel, so you can still finish turning automation on (#378).
- When the developer tools Poki needs cannot load, Connection says why and how to recover with Poki Setup. Automation confirmations now appear over Settings instead of replacing the Connection page (#368).
- A failed connection to the phone while the developer image is being mounted now shows as Stopped with the reason, instead of looking as though Poki is waiting for the network. Thanks to @ScottH1122 (#371).

### Chat
- Settings > Interface Size: follow the system text size, or choose one of seven standard and five accessibility sizes for chat and Settings, with a preview. Thanks to @ScottH1122 (#284).
- Attach JSON, Markdown and plain text files up to 100 KB each. The file shows its name and size and opens to the full text. It is kept with its message and sent again when you tap Retry. Thanks to @ScottH1122 (#370).
- The message field stays on one line when you tap into it.
- If you stop a task and switch to another conversation right away, the task's last steps and its stop message stay in the conversation where it ran. Thanks to @ScottH1122 (#253).
- When an agent cancels a task it handed to Poki, Poki's chat for that task stops too. Thanks to @ScottH1122 (#252).
- A task started while Poki is in the background shows its Live Activity once you return to Poki. Thanks to @ScottH1122 (#374).

### iPhone Duo
- Work in two apps side by side. If rotating the phone hides the workspace, Poki waits, with Stop still available, and resumes the same task once it sees the same two apps in the same layout. Your conversation and unsent draft are kept between full screen and split widths. Thanks to @Ryanwu316 (#354).

### Approvals and the relay
- Buttons whose sensitive word comes late in a long label, such as "Complete purchase of 3 items", now wait for your approval. Traditional Chinese words for purchase, subscription, transfer, delete, message and call are recognized as well. Thanks to @ScottH1122 (#372).
- Every new connection authorized through the relay now asks for your consent on the iPhone first. Refusing or not answering grants nothing, and existing connections keep working. If you run your own relay, deploy the updated Worker: an iPhone on an earlier Poki cannot approve new connections through it. Thanks to @ScottH1122 (#373).

### Poki Setup 0.2.3
- Runs natively on Intel Macs as well as Apple silicon (#365).
- Signed by a new Developer ID team. The install script accepts both the old and the new team (#381).
- When the same iPhone is connected over both USB and Wi-Fi, Poki Setup uses USB. Thanks to @ScottH1122 (#209).
- Signing in with an Apple Account no longer fails with "A Mac with macOS version 10.13 or later is required", and an anisette server that does not answer is skipped. Apple may ask for the sign-in code again the first time (#309).

Before you update from Poki Setup 0.2.2:
- macOS may ask for your Mac's login password to let Poki Setup use its keychain items. Enter the password and choose Always Allow.
- Poki Setup 0.2.2 cannot update itself to 0.2.3. When the disk image opens, drag the new Poki Setup into Applications to replace the old one. Updates after 0.2.3 install on their own.

## [0.4.1] - Unreleased

### Fixed
- When an in-app update reaches system installation, Poki explains how to close and reopen it if the update has not finished after 5 seconds. The instructions are available in English, Simplified Chinese, and Traditional Chinese. While the update is still uploading, Poki continues to ask you not to close it.

If you are updating from 0.4.0 and Poki stays on "Finishing the Update" after you tap "Install Update", swipe up on Poki in the app switcher to close it, then open Poki again.

## [0.4.0] Beta - 2026-11-14

Poki 0.4.0 replaces the whole interface of the iPhone app. Upgrading from 0.3.1 keeps your conversations: on the first launch after the update they move once to Archived Conversations in Settings.

### Interface
- A new home page where Poki's three-dimensional bear greets you by the time of day and shows whether Poki is working, waiting for you, done, stuck or asleep.
- Rows of everyday apps on the home page, sorted by your own tasks and the routines Poki remembers: tap one to start a task in it, press and hold to edit or remove it.
- A conversation drawer that shows each conversation's app icon and marks the ones that failed, stopped or are waiting for your answer.
- Archive the conversations you are done with and search them in Settings.
- App names you type, such as Notes, turn into capsules with the app's icon.
- Tap the bear to open a status card where you switch the model or the way Poki asks for approval.
- Setup problems, such as a signature about to expire or a relay that is offline, show on one line at the top, and a tap takes you to the fix.
- Dark mode under Settings > Appearance, and a new app icon with light, dark and tinted versions.

### Conversations
- Talk with Poki: when the message field is empty, the round button starts a spoken conversation that you can interrupt or end at any time.
- A spoken conversation stays in the chat and keeps going in the background, and the Dynamic Island shows whether Poki is listening, working or speaking. Talking needs a voice model key.
- Dictate with the microphone next to the message field, which you can hide in Settings.
- Send photos, camera shots and files from the plus menu; the model sees photos and the first four pages of a PDF.
- Answers render headings, lists, tables, quotes and code, also while they stream in.
- When a model request fails, Poki says why, such as an invalid key or no credit, and Retry sends it again with its images.

### Doing tasks
- Web lookups run in a browser inside Poki, not in Safari, and you can take over a page, hand it back or stop it; logins carry over to later tasks.
- Logins and captchas always stop and wait for you, while cookie, privacy and terms pop-ups are dismissed and the step says so.
- A sensitive step asks one short question, such as "Allow deletion?", in the chat card, in the Dynamic Island, on the Lock Screen and in a notification you can answer without opening Poki.
- Choose how Poki asks: reply in the chat, tap Allow or Don't Allow, or never ask. Payments, deletions and actions in Wallet always ask.
- Four sensitivity levels, from relaxed to asking about everything; on the first three your chat model first checks whether a step is what you wanted and writes its reason in the conversation.
- The Dynamic Island and Live Activity show the app Poki is working in, a short task name, each step and the time taken, with failed steps in red.
- Stop is quicker: Poki finishes the current step and stops, and your next message can go out right away.
- Poki reads the message field back before sending and checks that a message was really sent before it calls the task done.

### Call Poki from anywhere
- Press and hold the Action Button to talk to Poki, or set it to send a task.
- A Talk to Poki control for Control Center, the Lock Screen and the Action Button.
- Talk to Poki and Send Task to Poki in Shortcuts and Siri; a task sent this way runs without opening Poki and the reply arrives as a notification.

### Settings and updates
- Welcome pages on the first launch walk you through setup, the model and the microphone, and every step can wait.
- A Test Connection button on the model page sends one small request and tells you whether the key works.
- Settings are grouped into Connection, Models, Dictation and Mute, Approvals, Agents, Memory, Archived Conversations, Signing & Updates, Notifications, Appearance and Advanced.
- New tasks can start on cellular when the developer image is mounted, and Poki finds its pairing port again by itself if iOS changes it.
- After an update installs, Poki tells you to swipe it away and open it again instead of staying on "Closing Poki".
- Poki Setup on the Mac has an update-only command that keeps your conversations, model accounts, agents and settings.

## [Unreleased]

### Added
- 

### Changed
- 

### Fixed
- 

### Device checks
- docs/device-test-checklist.md: passed / not passed, with the date and iOS version.

## [0.1.0] - unreleased

First prototype: Poki pairs with the phone it runs on, keeps the runner up over the loopback, answers
MCP (look, do, status) through the person's own relay (no default; `deploy/cf-relay/deploy.sh`), and asks the owner on the Lock Screen
before sensitive actions.

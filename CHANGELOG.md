# Changelog

Poki and Poki Runner ship together under one version. Each entry says what changed for the person
using the phone, then what changed underneath. The working notes per round stay in
native/ios-app/CHANGELOG-round.md; this file is what goes into a release and the AltStore source.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).
Build numbers are the GitHub Actions run number of the release workflow.

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

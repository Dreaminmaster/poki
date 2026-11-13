# Agent install: steps, design and next stage

This note is for the people who maintain the install. The agent-facing guide is the skill [skills/install-poki/SKILL.md](../skills/install-poki/SKILL.md).

## Update preservation audit

This source audit is against `main` at `60c75491`. It is not a physical-iPhone preservation test. For a user asking to update, follow the separate [update branch](../skills/install-poki/SKILL.md#update-an-installed-poki), not the first-install command.

Poki Setup detects an existing matching bundle ID and uses an upgrade operation, without uninstalling first (`desktop/core/src/setup.rs:339-343`; `desktop/core/src/device/install.rs:39-73`). The narrower `renew` operation uses the recorded team and always requests an upgrade (`desktop/core/src/setup.rs:412-430`). A matching bundle ID, team and keychain access are prerequisites, not guarantees for an arbitrary signing tool. No app-data clear or whole-keychain reset appears in these update paths.

| Category | Source evidence and preservation boundary |
| --- | --- |
| Conversations | `native/ios-app/Poki/Sessions/SessionStore.swift:85-96,448-475` stores conversation JSON in Application Support/Poki/Sessions. The upgrade path does not delete those files. Expected to remain for a matching in-place upgrade; not tested on a phone here. |
| Model keys and model settings | `native/ios-app/Poki/Chat/ModelKeys.swift:164-222` uses the iPhone keychain for credentials and UserDefaults for provider/model choices. `src/install/run.mjs:467-485` can replace a credential only when model-key transfer is requested. `renew` has no model-key-transfer step. Keychain access still depends on the signing profile (`desktop/core/src/sign/entitlements.rs:5-30`). |
| Approvals and other app settings | `native/ios-app/Poki/App/AppModel.swift:72-100` persists approval mode in UserDefaults. `native/ios-app/Poki/App/SettingsVault.swift:10-34` mirrors only a selected subset of settings to the keychain. Container preservation is required; the vault is not a complete backup and does not justify deleting the app. |
| Apple Account and signing settings on the phone | `native/launcher/src/signer.rs:224-243` imports the Mac's signing key and sets a team only if none is saved. It does not sign out the phone's Apple Account or change its anisette setting. `desktop/core/src/apple/identity.rs:49-60` replaces the key for that team. `desktop/core/src/setup.rs:370-371,428-429` hands the key over on both install and renewal. Same-key updates retain the identity; a different key is a configuration change and must stop. Account state uses the installed keychain vault (`native/launcher/src/signer.rs:99-105`; `desktop/core/src/apple/store.rs:99-146`). |
| Selected update channel | The phone configures its own signer home (`native/launcher/src/signer.rs:118-129`); channel changes are explicit (`:194-197`). The checkout installer always saves its chosen channel on the Mac (`src/install/run.mjs:245-251`). `renew` reads the Mac's saved channel without setting it (`desktop/core/src/setup.rs:422`). Preserve both channels; a difference must be resolved before proceeding. |
| VPN, pairing and connection configuration | `desktop/core/src/device/container.rs:59-73` keeps existing pairing, except a legacy lockdown record can be replaced by a remote record. `renew` skips this setup step. The full installer can redeploy a relay when a token is present (`src/install/run.mjs:505-515`). UserDefaults holds relay settings (`native/ios-app/Poki/App/SettingsVault.swift:10-11`). External VPN app settings are outside this app, but working connectivity after update has not been verified here. Built-in VPN support can be lost as described below. |
| Extensions | `desktop/core/src/sign/mod.rs:73-85` removes packet-tunnel extensions, for paid and free teams alike. Other extensions come from the incoming IPA (`:93-106`), not from the installed app. A built-in-connection or custom-extension installation cannot be promised preservation through Poki Setup. Required extensions must match before an update; their operation after upgrade is not verified here. |

The team determines the generated bundle ID and App Group (`desktop/core/src/sign/mod.rs:38-55`). The full installer selects the currently chosen team (`desktop/core/src/setup.rs:115-125,317-319`), which need not be the old installation's team. The renewal path instead uses the recorded team, but does not compare the installed bundle and extensions before signing. Neither path checks the phone's numeric build for a downgrade before installation.

There is no general update-only mode that enforces every preservation requirement. The documented `renew` path is restricted to a known matching external build and unchanged signing setup. Built-in or custom installations, missing identity evidence and unresolved differences must stop. A code follow-up should add a preflight comparison of installed bundle ID, team, App Group, numeric build, required extensions and signing identity; reject mismatches before installing; and avoid signing-key import when the key is unchanged. The checkout installer also needs an explicit update-only path that does not change channels, transfer model credentials, pair again or deploy the relay. This documentation change does not implement those checks.

## Every step from zero, and who has to act

"Agent" means the installer does it with no window and no prompt. "Phone" means a person taps on the iPhone. "Input" means a person types something only they know.

| # | Step | Who | Can it go away, merge or move? |
|---|---|---|---|
| 1 | Download Poki Setup, check SHA-256, Developer ID and notarization | agent | Done by `bin/install-iphone.mjs`. A file fetched with `curl` carries no quarantine flag, so macOS shows no "downloaded from the internet" dialog, and the helper runs without the window. |
| 2 | Start Poki Setup | agent | The shipped `poki-setup-bridge` (JSON lines over stdio) is the headless mode. No change to Poki Setup was needed. |
| 3 | Choose the channel | agent | `set_channel`. |
| 4 | Apple Account password | input | Cannot go away: Apple's GSA sign-in needs it. Moved to the start, before any phone step. Typed once into the Mac's keychain with `security add-generic-password -w`, never in chat. Poki Setup keeps it for renewals, so it is asked once per Mac. |
| 5 | Two-factor code | input | Cannot go away. Once per Mac, since Poki Setup keeps the session. The code can arrive on the same iPhone. |
| 6 | Plug in by USB and unlock | phone | Needed for the first pairing and the install. |
| 7 | Trust This Computer and passcode | phone | Cannot go away: lockdown pairing needs the owner's consent. The RemotePairing record for iOS 26.4 and later is made in the same visit. Skipped when this Mac is already paired. |
| 8 | Developer Mode | phone | Cannot go away: development-signed apps do not launch without it, and the developer disk image needs it. On a phone with no passcode Poki Setup turns it on and the person only confirms after the restart. With a passcode, iOS refuses the remote switch, so Poki Setup reveals the switch and waits (Poki Setup 319). `devicectl` cannot turn it on either. |
| 9 | Sign and install Poki, pairing file, disk image | agent | Done by the bridge's `install`. |
| 10 | Trust the developer in VPN & Device Management | phone | Required for free accounts. Unverified: whether a paid team needs it, and whether `xcrun devicectl device process launch --payload-url "prefs:root=General&path=ManagedConfigurationList" com.apple.Preferences` can open that page directly (needs Xcode). |
| 11 | Open Poki once | phone | Poki writes `Documents/PokiSetup/poki-hello.json` each time it runs, and the installer reads it through the bridge's `container_read` (Poki Setup after 0.2.1) or `xcrun devicectl device copy from` (Xcode). Only with neither does the agent confirm with `done open_poki`. Poki then turns itself on: a first launch that finds Poki Setup's `signing-identity.json` sets `wantsOn`. Turning on asks for Automation Mode at once: the owner taps Continue and enters the iPhone passcode on iOS's screen. If they cancel, Poki does not ask again until it is turned on again. |
| 12 | Poki's Settings > Automation > Setup checklist (system permission prompts) | phone | iOS permission alerts need a tap. Not needed to finish the install; they come up the first time Poki needs each one. |
| 13 | Model API key for chat and voice | agent, when asked | `--model-key <provider>` reads the Mac keychain item `<provider>-api-key` and carries it sealed (below). Off by default. Without it, or with no way into Poki's files, typed on the phone. |
| 13a | Local connection (10.7.0.1) | phone | Poki Setup strips packet-tunnel extensions for both free and paid teams. A VPN app supplies the local connection; Settings > Automation > Setup > Local Connection includes LocalDevVPN instructions. Poki's hello carries one sentence for the VPN app it finds (`ProxyApps`), and the installer waits until Poki says it answers. |
| 14 | Relay | input | The Cloudflare token comes from `CLOUDFLARE_API_TOKEN` or the token Poki Setup keeps; the deploy is agent work. Scanning the relay QR on the phone is still a person step. Next stage: hand the relay address over like the pairing file. |
| 15 | Self-check | agent | Install record, Developer Mode, pairing, disk image mount, relay check. |

## Design of this stage

- **Data shape.** `src/install/steps.json` is the single list: the steps in order (`id`, `who`, `title`), the person stops (`waits`, each with one sentence) and the error codes (`errors`, each with `reason`, `agent_fix`, `person`, `retry`). The runner, the guide and the tests all read it, and a test fails when the guide misses a code.
- **Runner.** `src/install/run.mjs` walks the list. Each step is a method that returns a detail line, returns `{ skipped }`, or throws. `classify` turns bridge error kinds and messages into a code. Steps the phone can heal (`trust_not_answered`, `developer_mode_off`, `phone_locked`) run again by themselves. A person stop polls for its own evidence: the keychain item, a file the agent writes with `code` or `done`, or the bridge's own wait. `run.json` records each step, so a second run resumes.
- **Transport.** `src/install/bridge.mjs` talks to the shipped `poki-setup-bridge`. Passwords and tokens go to it over stdin. `src/install/fake-bridge.mjs` speaks the same protocol with a simulated iPhone and Apple Account. The dry run and the tests use it.
- **Hand-off files.** `src/install/container.mjs` reads and writes Poki's `Documents/PokiSetup/poki-hello.json` and `model-key.json`, through the bridge's `container_read` and `container_write` (two names only, `desktop/bridge/src/main.rs`) or Xcode's `devicectl`. Poki Setup 0.2.1 answers `unknown command`, which is how the installer tells. With neither, the steps fall back to asking the person. Poki's side is `native/ios-app/Poki/Setup/PokiHandoff.swift`.
- **Diagnostics.** `src/install/report.mjs` collects versions, step results, what usbmuxd, the USB bus, `devicectl` and Bonjour each see, and the last 40 log lines. `src/install/redact.mjs` removes identifiers and secrets. Poki Setup's own support bundle masks the Apple ID only and keeps UDIDs, device names and the relay address, so it is not used here.
- **Current alternative.** Poki Setup 0.2.2 and later include the `poki-setup` CLI in the downloaded app. Its `prompt` and `next --json` commands guide first installation without Node.js or a checkout. Existing installations use the guarded update branch above; `renew` uses the saved team and selected channel.

### What the diagnostics cover in issues #6, #55 and #60

| Issue | What the reporter needed | In the bundle |
|---|---|---|
| #6 usbmuxd lists no device on macOS 27.2 | macOS and Xcode versions; usbmuxd's list against the USB bus and `devicectl` | `system`, `devices.usbmuxd`, `devices.usb_iphones`, `devices.devicectl` |
| #55 RemotePairing over Wi-Fi fails | iOS version, link kind, whether the phone advertises `_remotepairing._tcp` | `phones[].ios`, `phones[].link`, `devices.remotepairing_adverts`, the pairing step's notes in the log |
| #60 JD search blocked after install | Poki build and a working device session | Only the environment part. The failure is in automating one app after the install, which is outside the installer. |

## Next stage: the install agent inside Poki Setup

Asked for on Nov 8: Poki Setup's first page asks for a model key, and an agent built into Poki Setup runs the same steps with it, diagnoses failures and drafts the issue. The same key then works in Poki on the iPhone.

- **No agent framework in Poki Setup today.** The iPhone app's loop is PiSwift (`xibbon/PiSwift`, MIT), whose package supports macOS 15 and iOS 18. Poki Setup for Mac can link `PiSwiftAgent` and `PiSwiftAI` (its floor moves from macOS 14 to 15, or the agent is offered on 15 and later). Poki Setup for Windows is Tauri and React, so it uses pi's TypeScript packages (`@earendil-works/pi-ai`, already a dependency of `agent/`).
- **Key kinds** follow `ModelProvider` in `native/ios-app/Poki/Chat/ModelKeys.swift`: Anthropic, OpenAI, Sign in with ChatGPT, DeepSeek, Gemini, OpenRouter and a custom endpoint. Poki Setup keeps the key with the core's `store::secret_set` (macOS keychain, Windows Credential Manager) under `model-key.<provider>`, the account name the iPhone uses.
- **One set of steps.** The runner moves into `desktop/core` and reads the same `steps.json` (`include_str!`). The bridge gains one command, `agent_install`, that emits these events. The model drives four tools: run the next step, read the last error, collect diagnostics, draft the issue. It never decides the step order. `bin/install-iphone.mjs` becomes a thin client of `agent_install`, so an outside agent and Poki Setup's own agent run the same code.
- **Carrying the key to the phone (built).** No plain key crosses USB. Poki makes a P-256 key in the Secure Enclave (a software key in the Keychain on a simulator) and puts its public half in `poki-hello.json`. The installer reads the key from the login keychain into its own memory, seals it with ephemeral ECDH, HKDF-SHA256 and AES-256-GCM (`src/install/model-key.mjs`), and writes only `model-key.json` (`poki.model-key/1`). The additional data binds the schema, the phone key's id, the provider, Poki's bundle id and a 10-minute expiry. Poki opens it (`ModelKeySeal.swift`), saves it with `ModelKeys.save`, selects the provider, deletes the file and the key pair, and says in its next hello which key it took. This is the construction GPT Pro's review asked for, done with plain ECDH rather than RFC 9180 HPKE so that it works with a Secure Enclave key on every iOS version Poki supports; `test/install-model-key.test.mjs` opens the installer's output with Poki's Swift code. Off by default: the agent asks the person and passes `--model-key`.
- **Split.** This PR is the shared steps, the outside-agent command, diagnostics and the issue template. The next PR adds `agent_install` to the bridge, the key page and agent in Poki Setup for Mac, the key hand-off in the core and the iPhone app, and Windows after that.

## Version, UI and renewal checks

Read the release selected by the installer, its installed version and build, and the phone's Settings > General > Updates > Poki Version. The Mac's saved install record is not a phone readback. Release suffixes such as `beta.1` are not the IPA's numeric build. See the skill's version-mismatch branch.

In 0.4.0, Settings opens from the button at the bottom of the conversations drawer. Models > Add Account replaces the old Agents > Accounts and Models instruction. The local connection is under Automation > Setup > Local Connection, which opens Turn On Loopback. External Agents contains Relay; General > Updates contains Signing Options, Apple Account and Release Channel. These names are checked against the views and localization strings, not a live UI session.

The installer closes its headless helper when it exits (`src/install/run.mjs:598-600`). It does not leave a renewal service running. The Poki Setup Mac app stays open after its last window closes (`desktop/mac/Sources/PokiSetup/App.swift:48`), checks every six hours (`AppModel.swift:113-120`) and renews with two days or fewer remaining (`desktop/core/src/keeper.rs:6,33-35`). The renewal task requires a kept password (`AppModel.swift:330-333`) and a reachable trusted phone. Keep the Mac awake and Poki Setup running for that method. Automatic renewal while locked, asleep or disconnected is not verified here.

The phone can instead prepare its own refresh after a separate Apple Account sign-in, but the owner still taps Install. For the reported 0.4.0 update that installed successfully but stays on Finishing the update, swipe Poki away and reopen it, then read back the version. That operation does not delete app data. The status text itself can appear before completion (`native/ios-app/Poki/Signing/SelfSigner.swift:395-405`), so it cannot prove success.

## Checks on a real iPhone (not done yet)

1. Use a dedicated iPhone with no existing Poki data, then run `node bin/install-iphone.mjs run --udid <udid>` from zero with the phone locked by a passcode.
2. Compare `node bin/install-iphone.mjs phones` with `xcrun devicectl list devices` on macOS 27.3 (the #6 symptom).
3. Tap Don't Trust once and confirm `trust_not_answered` retries.
4. Confirm whether step 10 appears for a paid team, and try the two `devicectl` shortcuts in steps 10 and 11.
5. Run `diagnose` with the phone attached and read the bundle for anything left in.

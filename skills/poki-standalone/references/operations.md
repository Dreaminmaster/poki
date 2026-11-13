# Run Poki on an iPhone without a connected computer

This guide covers a custom signed installation and a self-hosted relay. For ordinary first installs, updates, renewal, or failed downloads on the phone, use [install-poki](../../install-poki/SKILL.md) first. Its preservation gate also applies here. Keep the installed bundle ID, signing team, App Group, channel and required extensions during an update. Poki Setup removes packet-tunnel extensions, so it cannot preserve a custom built-in connection.

Current UI paths below follow the 0.4.0 source on `main`. Open Settings with the button at the bottom of the conversations drawer. The physical-device results in section 9 belong to November 7, 2026 and an older build. They do not verify these current instructions. Paths are relative to the repository root unless stated otherwise.

## 1. Runtime and completion criteria

The iPhone makes an outbound connection to the relay. The relay forwards MCP requests and replies; PokiCore runs the tools on the phone. PokiLauncher reaches local developer services. On iOS 27 and later, native services are the default automation path. Earlier versions use XCTest; an explicitly selected legacy Runner path needs a separate Poki Runner app.

| Level | Required observation |
| --- | --- |
| Configuration | Developer services reachable, phone paired, automation available, relay ready and client authenticated. |
| Independent basic operation | USB disconnected; a new cloud task calls tools and the target app visibly opens or changes as requested. |
| Full device acceptance | The agreed app tasks, approvals, background, lock, restart, network and failure-recovery checks all have results. |

If only basic operation passes, report that boundary. Do not call it full device acceptance.

## 2. Prerequisites and connection choice

Identify the authorized iPhone, remote client account, relay account and signing team. Source builds require full Xcode, Rust, XcodeGen, Python 3 and Node.js. Read `.github/workflows/ios-app.yml`, `ios-runner.yml` and `deploy/cf-relay/DEPLOY.md` for current build inputs. The normal Poki Setup install does not require Xcode.

The historical check used iOS 27.3. Other versions require their own acceptance. An older phone can import its pairing record through Poki Setup instead of on-phone pairing.

| Connection | Requirement | Signing boundary |
| --- | --- | --- |
| Existing VPN or LocalDevVPN | Route `10.7.0.1` back to the phone; keep the user's other network settings. | Works with the external build. A free Apple Account can use this path with seven-day signing. |
| Built-in connection | User explicitly accepts a system VPN configuration and any effect on another VPN. | Separately sign the app and tunnel extension with matching Network Extension entitlements and profiles. A paid membership alone does not make Poki Setup retain the extension. |

The built-in tunnel handles IPv4 TCP for `10.7.0.1`; it does not add an internet default route or DNS settings. It still uses the system VPN facility and can disconnect another VPN. Done when the authorized connection method and its signing requirements are known.

## 3. Build, sign and install

### 3.1 Identify the build

Check the worktree, branch and commit. Use app artifacts from `.github/workflows/ios-app.yml`; use `ios-runner.yml` only for the legacy Runner path. A local unpublished commit needs its own artifact, not another revision's latest build.

- `Poki-unsigned.ipa` includes the built-in tunnel.
- `Poki-external-unsigned.ipa` omits it and needs an external local connection.
- `Poki-signing.zip` contains the entitlements for signing.
- `poki-runner-unsigned.ipa` is only for the Runner path.

The historical Runner check used device developer-disk-image frameworks. Keep and sign the Runner's own dependencies. Done when the artifact revision and required extensions are identified.

### 3.2 Register identifiers

For a new custom installation, register identifiers and groups in the [Apple Developer account](https://developer.apple.com/account/), then create matching profiles. For an update, retain the installed identifiers instead of generating new ones.

| Object | Example for a new installation |
| --- | --- |
| Poki | `com.example.poki` |
| Live Activity extension | `com.example.poki.widgets` |
| Tunnel extension | `com.example.poki.tunnel` |
| Shared App Group | `group.com.example.poki` |
| Legacy Runner | `com.example.poki.WebDriverAgentRunner.xctrunner` |

Poki and its Live Activity extension share an App Group. The built-in connection also requires `packet-tunnel-provider` capabilities. Wildcard profiles do not replace capability-specific profiles. If Apple requires a new developer agreement, the account holder accepts it. Passcodes, account verification and system VPN confirmation are the user's actions. Done when all profiles match the intended identifiers and capabilities.

### 3.3 Build locally

Set `TEAM_ID`, `APP_BUNDLE_ID`, `APP_GROUP` and `BUILD_DIR` privately in the terminal. From the repository root:

```sh
native/launcher/fetch-idevice.sh
rustup target add aarch64-apple-ios
cargo build --release --locked --target aarch64-apple-ios \
  --manifest-path native/launcher/Cargo.toml
native/ios-app/scripts/make-assets.sh
xcodegen generate --spec native/ios-app/project.yml
xcodebuild build \
  -project native/ios-app/Poki.xcodeproj -scheme Poki \
  -configuration Release -destination generic/platform=iOS \
  -derivedDataPath "$BUILD_DIR" ARCHS=arm64 \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  POKI_BUNDLE_ID="$APP_BUNDLE_ID" POKI_APP_GROUP="$APP_GROUP"
```

For the external build, use `project-external.yml` and `PokiExternal.xcodeproj`, still with scheme `Poki`. To export signing inputs from a built app:

```sh
python3 native/ios-app/scripts/export-signing.py \
  "$APP_PATH" local "$SIGNING_OUTPUT_DIR"
```

Use `external` instead of `local` for the external build. The exporter reads the built Info.plist. An unresolved `$(POKI_APP_GROUP)` is not a valid group. Done when the build succeeds and the exported identifiers are concrete and match the intended installation.

### 3.4 Inspect nested signatures

Inspect every Mach-O executable in the app, extensions, libraries and frameworks. Sign inner dependencies before their containing bundles. For Runner, check both `Frameworks/libPokiRunnerHost.dylib` and the dependencies under `PlugIns/WebDriverAgentRunner.xctest/Frameworks/`.

A top-level `codesign --verify --deep --strict` result alone is insufficient. The historical run passed that check but failed to launch with `NSError 103` because an inner framework was unsigned. Run `codesign --verify --strict` and inspect TeamIdentifier with `codesign -dv` for each executable. Done when nested signatures and profiles match, including both apps for the Runner path.

### 3.5 Install and prepare the system

Use the established signing tool or Xcode device installation. With Xcode's CLI:

```sh
xcrun devicectl device install app --device "$TEST_UDID" "$APP_PATH"
```

`TEST_UDID` must identify the authorized device. For an update, complete the install skill's preservation checks first. Never delete the existing app to work around a signature mismatch. For Runner, install `$RUNNER_PATH` with the same signing setup and launch Poki with `-automationPath runner` for that launch.

Ask the user to unlock and accept Trust This Computer as needed. Then complete the phone steps:

1. Enable iOS Settings > Privacy & Security > Developer Mode, restart and confirm. Done when the mode is on after restart.
2. Enable iOS Settings > Developer > Enable UI Automation when the automation path requires it. Done when the switch is on.
3. Complete developer trust if iOS asks. Some signing teams have no such entry. Done when Poki opens without a trust error.
4. Open Poki and complete its Automation Mode prompt. For Runner, open Runner to check its launch screen, then return to Poki. Done when the selected automation path works.

If Developer Mode is missing, use the installer or Xcode preparation instructions for that phone. Do not install an unrelated Runner merely to expose the menu. Finish by reading the version and build in Poki at Settings > General > Updates > Poki Version. Preserve other automation apps and their state.

## 4. Local connection, pairing and background operation

### 4.1 Built-in connection

Only for a build that includes the tunnel, open Settings > Automation > Setup > Local Connection. Under Other Ways, use Enable Local Connection. The user accepts the system VPN prompt. Done when developer services answer and an ordinary webpage still loads through the expected route. A saved VPN profile or Connected label alone is insufficient.

### 4.2 Existing VPN or LocalDevVPN

On the same Local Connection page, choose the app under Use Your Proxy App. Follow its instructions to set the actual loopback address to `10.7.0.1`, then keep it connected. Reopen its settings to confirm the value was saved rather than left as placeholder text. Preserve subscriptions, nodes and unrelated routes.

The LocalDevVPN page has the App Store link and configuration instructions. If switching from a built-in connection, Use the Current VPN selects the external route. Done when the loopback reports Working, developer services answer, and the user's existing network access works. An incompatible VPN requires a user-approved alternative; do not silently replace network configuration.

### 4.3 Pair on the phone

With the local connection working, open Settings > Automation > Setup > Pair This iPhone. Follow the current Pair This iPhone page. On the supported on-phone path, Poki directs the user to iOS Settings > Privacy & Security > Developer Mode > Pair with Poki. The user reads the code in Poki and enters it in iOS, never in chat. Keep pairing active while switching apps.

Done when Poki reports pairing complete and the record is present and valid. Record only that result, not the record's contents. If the system entry is absent, inspect the current instructions and pairing state. The historical run had stale Live Activity text, so it did not prove code display in the Live Activity. Replacing pairing records requires authorization for that app's record.

### 4.4 Start and retain the session

Complete Settings > Automation > Setup > Stay On in Background, including the system permission prompts needed by the selected path. Avoid recording location permission maps. Keep Poki available in the background during normal operation. Swiping it away is a recovery step for a stalled update, followed by reopening it; it is not normal background operation.

Prepare the developer disk image and start Poki. For XCTest, `in-process session ready` is useful session evidence; native automation on iOS 27 requires a real screen read or action instead of assuming that log must appear. Runner adds a launching state and can sleep according to its idle setting. Done when the selected path handles a new authorized tool request and its actual result is observed.

Check reconnect, lock, restart and background recovery separately. The historical in-process description is not proof of those cases. Follow install-poki's renewal instructions: keep the Mac awake and Poki Setup running if relying on its automatic renewal, or configure the phone's signing account and confirm each refresh installation.

## 5. Deploy the relay

Read `deploy/cf-relay/DEPLOY.md`. Use an authorized Cloudflare account and a separate Worker. Complete normal account login if needed. Save command output outside the repository in a private log because it contains the real address:

```sh
umask 077
relay_task_dir=$(mktemp -d)
deploy/cf-relay/deploy.sh --name "$RELAY_NAME" \
  > "$relay_task_dir/deploy.log" 2>&1
```

Enter the HTTPS address in Poki at Settings > External Agents > Relay. Keep existing secrets on redeployment so connected clients remain valid. Read the deployment guide for production logging settings. After the relay is ready, use Add Agent to create a separate connector for this client.

Connector URLs contain credentials and belong only in private client configuration. The relay uses MCP Streamable HTTP and OAuth registration, PKCE and token exchange. Possession of the connector URL grants access to its authorization flow, so treat the URL as a secret. Done when a real authenticated client receives a reply from the phone. A deployment dry run or reachable URL alone does not pass.

## 6. Connect a cloud client

The historical run used Codex inside the ChatGPT iOS app and a custom MCP plugin configured in a browser. Client interfaces and feature availability can change. Check the client's current official instructions instead of assuming the historical labels are still present.

1. In the account used on the phone, add a private custom remote MCP connector with the generated Server URL and OAuth. Done when it is connected under that account.
2. Select the cloud environment and connector for a new task on the phone. Done when the task shows the intended environment and integration.
3. Send an authorized minimal task, such as opening Clock and reading its screen. Done when actual tool calls and the phone result are visible.

Never record forms containing connector URLs or tokens. Verify the actual `tools/list` reply and the client's exposed tools separately. The standalone relay's `look`, `do` and `status` are not the Mac MCP server's tool catalog. A write-tool grouping can show only `do` without describing the whole protocol.

An example authorized `do` request is:

```json
{"actions":[{"launch":"com.apple.mobiletimer"}]}
```

Verify the returned screen and the device. Do not pass off a private script as a real client task.

## 7. Unplugged and full acceptance

Ask the user to disconnect USB and record the iOS version and Wi-Fi or cellular connection. Close only unrelated control sessions created for this check. Start a new cloud task, then verify screen reading, app launch and an in-app action separately. Done when the requested result is observed without USB.

For full acceptance, follow sections 0 through 6 of `docs/device-test-checklist.md`, adapting the client name. Keep independent results for Clock and Notes tasks, five minutes in the background, lock and restart, Wi-Fi and cellular transitions, failure recovery, approvals and Live Activities. Use dedicated test assets for destructive cases and obtain the required authorization. The user approves sensitive actions; the agent must not approve its own request.

Record failures, retry behavior and untested cases. If a demonstration is requested, record from a non-private screen and keep approvals in a separate recording. Existing screenshots are not a video. Done when each agreed acceptance item has evidence or an explicit untested result.

## 8. Historical failures and recovery

These failures were observed on November 7, 2026. Runner-specific rows apply only to that path.

| Symptom | Check and recovery | Proof |
| --- | --- | --- |
| Apple requires a developer agreement | The account holder accepts it in the developer account. | Signing and installation succeed. |
| App Group mismatch | Match profiles and group membership; export entitlements from the built app. | Built identifiers, entitlements and profiles agree. |
| VPN connected but services unavailable | Verify the saved loopback value and selected connection. | Developer services answer and ordinary browsing works. |
| Pairing entry missing after leaving Poki | Keep pairing active and use a build with the relevant background fix. | System pairing entry appears and pairing succeeds. |
| Pairing code cannot be captured | The user reads it in Poki and enters it in iOS. | Pairing completes with a valid record. |
| Runner launch returns NSError 103 | Inspect every nested executable and dependency signature. | Signatures are valid and Runner reaches running. |
| New connector absent in client | Check account and installed integrations; refresh the client. | A cloud task can select and call it. |
| Runner sleeps while idle | Check idle settings and send a new authorized tool call. | Runner wakes and returns a screen. |

An untrusted-developer message alone does not establish the cause. The historical Runner failure was fixed by correcting local artifact signing, not repository code. Runner exposes port 8100 on the LAN; relay authentication does not protect direct access to that port. The in-process path does not open it.

## 9. Historical verification boundary

The November 7, 2026 installation used `8bcd387`, based on the older iOS app revision `e806589`. It used Poki plus Runner and did not verify the in-process or current native path.

| Area | Recorded result |
| --- | --- |
| Signing | Both apps installed under the same team; Runner worked after nested signing was corrected. |
| Connection | Built-in developer-service access worked earlier; independent operation reused an existing VPN and retained web access. |
| Pairing | The user entered the code; pairing completed and the record was valid. |
| Startup | Runner took about 17.8 seconds from connecting to running; first disk-image mounting after restart was not covered. |
| Relay | A real phone connected through a user-hosted relay; OAuth, initialization and tool discovery succeeded. |
| Screen read | One pre-disconnect read took about 1.49 seconds with 14 elements; one unplugged read took about 2.22 seconds with 90 elements. |
| Cloud task | A task called `do` to open WeChat in about 8.58 seconds; the user confirmed the app opened. |
| Independence | The user confirmed USB was disconnected, Wi-Fi was active and the task used a cloud environment. |

Those timings are historical samples, not current performance claims. Opening WeChat did not authorize sending or reading messages. Reproduction can use Clock instead.

Not completed in that run: Clock city creation, a Notes task, independent in-app tap acceptance, all approval branches, five-minute background operation, two-minute lock, restart, cellular transitions, interruptions, offline behavior and complete Live Activity checks. Pairing-code display in the Live Activity needed another check. No complete demonstration or separate approval video was recorded.

## 10. Maintenance and delivery

Copy the whole `skills/poki-standalone/` directory, including this reference, into the client's skill directory. Inspect local changes before updating an existing copy. The personal Codex skill directory is normally `~/.codex/skills/`.

Report the actual installed commit, documentation commit, baseline, results, network conditions, redacted evidence and untested items. Keep source changes distinct from locally repaired build artifacts. Another branch's review does not automatically cover this one.

Change or remove connections only when requested. Removing a connector revokes access; stopping Poki ends its current service. Preserve other network configuration and user applications. Done when the authorized results and limitations have been delivered.

Reference entry points:

- App and runtime: `native/ios-app/`, `native/ios/PokiCore/`, `native/ios/PokiLoopback/`, `native/launcher/`.
- Builds: `.github/workflows/ios-app.yml` and, for Runner, `.github/workflows/ios-runner.yml`.
- Relay: `deploy/cf-relay/deploy.sh` and `deploy/cf-relay/DEPLOY.md`.
- Device acceptance: `docs/device-test-checklist.md`.

# Poki repository guide

To install or update the Poki iPhone app for a user, follow [skills/install-poki/SKILL.md](skills/install-poki/SKILL.md). To install or update Poki MCP or Poki Agent for a user, follow [docs/install-with-an-agent.md](docs/install-with-an-agent.md).

This file guides agents developing inside this repository. Current iOS app development targets version `0.5.0` (`native/ios-app/VERSION`) for iOS 18 and later, with Xcode 27.1 and the iOS 27.1 SDK required for full-panel iPhone Duo builds. Poki Setup is at `0.2.8` (`desktop/Cargo.toml`). Poki MCP and Poki Agent (`src/`, `native/bridge/`, `agent/`) are frozen for new features and receive targeted security maintenance only.

## Repository layout

| Area | Path | What lives here |
| --- | --- | --- |
| iOS app | `native/ios-app/` | SwiftUI app (`Poki/`), Live Activity widget (`PokiWidgets/`), shared code and String Catalogs (`Shared/`), local packet-tunnel extension (`PokiTunnel/`), and unit tests (`PokiTests/`). Xcode projects are generated from `project.yml` or `project-external.yml` (both include `project-base.yml`). See [native/ios-app/README.md](native/ios-app/README.md). |
| PokiCore and Swift packages | `native/ios/` | `PokiCore` (platform-independent on-phone MCP server, approvals, and runner supervision; spec in [docs/ios-core.md](docs/ios-core.md)), `PokiLoopback` (local TCP loopback stack for `PokiTunnel`), and `RelayCheck`. |
| On-phone Rust launcher | `native/launcher/` | `PokiLauncher` static library (`libpoki_launcher.a`) and C header (`include/poki_launcher.h`) linked into the iOS app. Fetches pinned `idevice` and applies `native/patches/` via `native/launcher/fetch-idevice.sh`. |
| Simulator test targets | `native/ios-gym/`, `native/ios-runner/` | `PokiGym` stress-test app for automation scorecards and the legacy WebDriverAgent runner sources. |
| Poki MCP daemon and Rust bridge | `src/`, `bin/`, `test/`, `native/bridge/`, `agent/` | Node.js 24+ MCP daemon (`src/daemon.mjs`), stdio bridge (`src/stdio.mjs`), iPhone installer CLI (`bin/install-iphone.mjs`), Rust physical-device bridge (`native/bridge/`, see [native/NATIVE.md](native/NATIVE.md)), host helpers (`native/ocr.swift`, `native/simulator.m`), and terminal agent (`agent/`). |
| Poki Setup | `desktop/` | Rust workspace (`desktop/Cargo.toml`: `core`, `cli`, `bridge`, `app/src-tauri`), Windows Tauri/React UI (`desktop/app/`), and native macOS SwiftUI app (`desktop/mac/`). See [desktop/README.md](desktop/README.md) and [desktop/mac/README.md](desktop/mac/README.md). |
| Relay and deployment | `deploy/` | Self-hosted Cloudflare Worker relay (`deploy/cf-relay/`), proxy loopback modules (`deploy/proxy-modules/`), and router configs (`deploy/istoreos/`). |
| Docs and skills | `docs/`, `skills/` | Architecture specs, user guides, release flow, and agent skills. |
| Website | External repository | `poki.bot` is hosted outside this repository. Only site links and the R2 release catalog config (`config/release-source.json`) live here. |

## Build and test

Run commands from the repository root unless a command uses `--package-path`, `--manifest-path`, or `--prefix`. In a fresh worktree without `node_modules`, run `npm ci` at the root (or `npm ci --prefix <dir>` for `agent`, `desktop/app`, and `deploy/cf-relay`) before running Node tests or frontend builds. Generated Xcode projects, `Info.plist`, and `.entitlements` files under `native/ios-app/` are gitignored; edit `project-base.yml`, `project.yml`, or `project-external.yml` instead.

### iOS app (`native/ios-app/`)

Build `PokiLauncher` for the simulator target first (including `rustup target add aarch64-apple-ios-sim`, see below) if `native/launcher/target/aarch64-apple-ios-sim/release/libpoki_launcher.a` is not present.

```sh
# 1. Build assets and generate the Xcode project
native/ios-app/scripts/make-assets.sh
xcodegen generate --spec native/ios-app/project.yml

# 2. Build unsigned Debug for the iOS Simulator (default build with local tunnel)
xcodebuild build \
  -project native/ios-app/Poki.xcodeproj -scheme Poki -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/sim \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64

# 2b. External build without packet-tunnel entitlements generates PokiExternal.xcodeproj
xcodegen generate --spec native/ios-app/project-external.yml
xcodebuild build \
  -project native/ios-app/PokiExternal.xcodeproj -scheme Poki -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/sim-external \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64

# 3. Run PokiTests inside Poki on a booted simulator (project.yml / Poki.xcodeproj only)
# Replace with a booted UDID from: xcrun simctl list devices booted
SIMULATOR_UDID="YOUR_BOOTED_SIMULATOR_UDID"
native/ios-app/scripts/app-tests.sh "$SIMULATOR_UDID"
```

### PokiCore, PokiLoopback, and PokiLauncher

```sh
swift test --package-path native/ios/PokiCore
swift test --package-path native/ios/PokiLoopback

# PokiLauncher (Rust static library for the iOS app)
native/launcher/fetch-idevice.sh
rustup target add aarch64-apple-ios-sim           # Add aarch64-apple-ios for device builds
cargo metadata --locked --format-version 1 --manifest-path native/launcher/Cargo.toml > /dev/null
cargo test --manifest-path native/launcher/Cargo.toml
cargo build --release --locked --target aarch64-apple-ios-sim --manifest-path native/launcher/Cargo.toml
```

### Poki MCP daemon, Rust bridge, and Poki Agent

```sh
npm test                                          # All root Node.js tests
node --test test/issue-template-check.test.mjs    # Run one test file
npm test --prefix agent                           # Poki Agent tests
npm run build:native                              # Rebuild build/ocr, build/simulator, build/poki-native
cargo test --manifest-path native/bridge/Cargo.toml
```

Both `npm run build:native` and `cargo test --manifest-path native/bridge/Cargo.toml` require `.deps/idevice`, which `./bin/setup` fetches.

### Poki Setup (`desktop/`) and relay (`deploy/cf-relay/`)

```sh
cargo metadata --locked --format-version 1 --manifest-path desktop/Cargo.toml > /dev/null
POKI_SETUP_FILE_SECRETS=1 cargo test -p poki-setup-core -p poki-setup-cli --manifest-path desktop/Cargo.toml
swift test --package-path desktop/mac
desktop/mac/scripts/bundle.sh native "$PWD/dist"  # Use universal for release DMGs
npm --prefix desktop/app run build                # Type-check and bundle the Windows Tauri UI
npm --prefix deploy/cf-relay test                 # Cloudflare Worker relay tests
```

## UI changes and tests

- **Attach before-and-after screenshots for UI changes.** For any change to the iOS app, Live Activity, or Poki Setup UI, capture before-and-after screenshots (light and dark mode when relevant) and put them in the pull request under `## Screenshots or screen recording`. For iOS views, use the Simulator launch flags in [native/ios-app/README.md](native/ios-app/README.md), such as `-pokiScreen` and `-pokiChat`.
- **Write regression tests that fail on the old code.** Every bug fix needs a test that reproduces the defect before the fix and passes after it. Avoid tests that only mirror mock call order or pass unchanged on the unpatched code.
- **State your real test surface.** Note in the pull request whether you tested in unit tests, on a Simulator, or on a physical iPhone, and name anything left untested.
- **Keep localization in sync.** iOS UI strings live in `native/ios-app/Shared/Localizable.xcstrings`, Live Activity strings in `Shared/LiveActivity.xcstrings`, and permission prompts in `Poki/InfoPlist.xcstrings` (English, Simplified Chinese, and Traditional Chinese). Follow [GLOSSARY.md](GLOSSARY.md) and [docs/ios-localization.md](docs/ios-localization.md).

## Contribute code

The full release flow is in [docs/release-channels.md](docs/release-channels.md), and contribution scope rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

1. **Branch from `main`.** `main` is protected. Never push to it, force-push it, or rebase it. `contributor-signatures` is a data branch maintained by Poki Repo Bot (`signatures.json`); never base work on it, push to it by hand, or delete it. Do not base work on retired branches such as `standalone` or `poki/ios-integration`. Name branches `dev/<topic>` (or `feat/<topic>`, `fix/<topic>`, `docs/<topic>`), one change per branch, never `claude/...` or a session name.
2. **Use public English conventions.** Write code comments, documentation, commit messages, and pull requests in English. Use short imperative Conventional Commits (`feat(ios): ...`, `fix(setup): ...`, `docs: ...`, `test(launcher): ...`, `chore(mcp): ...`) or clear imperative English subjects. Keep internal ticket numbers, personal emails, local machine paths, secrets, tokens, pairing records, passcodes, and private screen contents out of commits and pull requests.
3. **Open a pull request into `main`.** Fill in [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md), including the `AI assistance:` line. Open an issue first for large changes (new features, phone-operation changes, setup or main UI flow changes, or 10 or more files; see [CONTRIBUTING.md](CONTRIBUTING.md#when-to-open-an-issue-first)). On a contributor's first pull request, Poki Repo Bot asks them to agree once to [CONTRIBUTOR_AGREEMENT.md](CONTRIBUTOR_AGREEMENT.md). Show that request to the user and never post the agreement comment on their behalf.
4. **Pass `PR checks`.** `.github/workflows/pr-checks.yml` runs on Linux and Windows (Poki Setup core and CLI tests, `cargo metadata --locked` for `desktop/` and `native/launcher/`, `actionlint`, and release-contract Node tests) and must pass. After changing `desktop/` or `native/launcher/` dependencies, run `cargo metadata --locked` for that manifest before pushing. Do not dispatch macOS workflows unless asked; GitHub runs at most 5 concurrent macOS jobs for this repository.
5. **Follow release and hotfix rules.** A fix for a version already in Beta lands on `main` first, then a separate PR cherry-picks it into `release/X.Y`. Release branches take fixes only, never features. Do not cut releases by hand, push `app-*`, `ios-*`, or `desktop-*` tags, or edit `.github/channels.json` or `native/ios-app/VERSION` except in a promotion PR or a minor version bump requested by the repository owner. Every merge into `main` builds a Pre-alpha automatically (`prealpha.yml`). Publishing Alpha, Beta, Stable, or uploading installers requires the repository owner's approval; agents never approve on the owner's behalf. For `scripts/release/publish-compat.sh`, agents may run `check`, while `draft` and `public` are owner-only.
6. **Leave other people's branches alone.** Never force-push or rewrite a branch you did not create.

## File an issue

When a user asks you to report a problem or request a feature, format the body to match one of the [issue forms](.github/ISSUE_TEMPLATE). `gh issue create --body` skips the forms, and the automated check labels unmatched issues `state:needs-info`.

1. **Search first.** Run `gh issue list --repo JosssphZhou/poki --state all --search "<key words>"`. If an existing issue covers the problem, add a comment with new evidence instead of opening a duplicate.
2. **Pick one form.** One problem per issue. Working setups, ports, install paths, or test results with no fix requested go in [Discussions](https://github.com/JosssphZhou/poki/discussions/new?category=field-reports) under Field reports.

   | Form | Use it for | Required headings, in order |
   | --- | --- | --- |
   | `bug_report.yml` | The Poki iPhone app, Poki Setup, Poki MCP, or Poki Agent does not work as documented | Problem description, Steps to reproduce, Affected area in Poki, Poki version, iPhone model and iOS version, Connection method |
   | `install-failure.yml` | Installing Poki on the iPhone stopped at a step | Problem description, Failed installation step, Installation method, Diagnostics output, Poki and Poki Setup versions, iPhone model and iOS version |
   | `task_failure.yml` | The tools work, but a real task in a specific app does not finish | Requested task, Point of failure, Client or integration, Poki version and model, iPhone model and iOS version, Run trace |
   | `feature_request.yml` | A capability, speed-up, or design proposal | Goal or use case, Current limitation, Affected area in Poki |

3. **Write the body.** Read the chosen form file under `.github/ISSUE_TEMPLATE/`. Use one `### <label>` heading per field, with the exact English label in the form's order. Use dropdown options verbatim. Keep every required heading, and write `_No response_` under optional headings you cannot fill. Answers may be in the user's language.
4. **Keep it reviewable and clean.** Separate what you observed from what you inferred, include versions and commits, and quote exact error text. Remove passcodes, tokens, Apple account details, pairing records, phone numbers, and private screen contents.
5. **Confirm before submitting.** Write the body to a file, show the user the title and body, and run `gh issue create --repo JosssphZhou/poki --title "<specific title>" --body-file <file> --label <labels>` only after they approve. Pass the form's type label (`type:bug`, `type:task-failure`, or `type:feature`; Install failure also takes `area:install`). Report vulnerabilities through [private reporting](https://github.com/JosssphZhou/poki/security/advisories/new), never in a public issue. If an issue is flagged `state:needs-info`, edit it in place with `gh issue edit <number> --body-file <file>` rather than opening a duplicate.

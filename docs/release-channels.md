# Release channels

Poki's iPhone builds are published as GitHub Releases on this repository. Poki Setup (the desktop
installer) reads them and lets each person pick a channel in Settings. A channel decides which
releases Poki Setup installs and renews with.

| Channel | Tag | Title | GitHub release | Who it is for |
| --- | --- | --- | --- | --- |
| Stable | `app-X.Y.Z` | Poki v0.3.0 | its own full release | everyone |
| Beta | `app-X.Y.Z-beta.K` | Poki v0.3.0 Beta 1 | its own prerelease | testers |
| Alpha | `app-X.Y.Z-alpha.N` | Poki v0.3.0 (712) Alpha | rolling `app-alpha-latest`, prerelease | early testers |
| Pre-alpha | `app-X.Y.Z-prealpha.N` | Poki v0.3.0 (712) Pre-alpha | rolling `app-prealpha-latest`, prerelease | developers |

A channel includes the channels above it: Beta installs the newest Stable or Beta release, Alpha
the newest Stable, Beta or Alpha, and Pre-alpha the newest release of any kind. Poki Setup's own
updates (`desktop-v*`, `desktop-alpha-*` and `desktop-prealpha-*` tags) follow the same channel.
If no installable release exists in a channel or any more stable channel it includes, Poki Setup
tries the next less stable channel, in the order Stable, Beta, Alpha, Pre-alpha. This is `pick` in
`desktop/core/src/release.rs`, not a change to the saved channel.

**When Stable and Beta have no release of their own, they fall back to Alpha.** A person on Stable
or Beta then installs and renews with the newest Alpha build until a Beta or Stable release is
published, and keeps the channel they chose.

The checkout installer defaults to Alpha (`bin/install-iphone.mjs`); Poki Setup without a saved
choice defaults to Stable. Read current release metadata on each run, and do not silently switch
an existing user's channel.

## When GitHub refuses the release list

Poki Setup, the checkout installer and the iPhone app read the release list from `api.github.com`
without signing in. GitHub limits these anonymous requests per network address, 60 an hour, and
everyone behind the same address shares that limit. Over it, GitHub answers 403 or 429, and the
error reads `Could not read Poki's releases from GitHub` with the status. The phone shows Not Found
as the newest version on its channel instead.

Retrying at once does not help, because each attempt is another request against the same limit. Switch to
another network or proxy node and try again, or wait an hour. In Poki Setup, Install from an IPA
File installs a `Poki-external-*.ipa` and the `Poki-signing.zip` beside it downloaded from the
release page in a browser, which does not read the list. Use it only over a Poki signed with the
same Apple Account.

Poki Setup orders versions so that `0.3.0-beta.1 < 0.3.0-beta.2 < 0.3.0 < 0.3.0-712`: a pre-release
suffix sorts below the plain version, a build number above it.

Until November 2026 app releases were tagged `ios-vX.Y.Z`, `ios-vX.Y.Z-beta.K`, `ios-alpha-X.Y.Z-N` and
`ios-prealpha-X.Y.Z-N`; Poki Setup reads both schemes. Older Poki Setup builds that do not recognize `app-*` still need the old
rolling releases `ios-prealpha-latest` and `ios-alpha-latest`, which carry the Poki Setup update too.
Compatibility depends on the build, not just the 0.2.2 version label: revision `481faf22`, whose main commit count is
661, already recognizes both schemes. This is a source check, not a check of the shipped binary. Pre-alpha and Alpha continue to publish those compatibility
copies. Betas and stables exist only as `app-*`.

N is the commit count of the built commit on `main`, so it only goes up while `main` is never
rewritten. Betas and stables drop it from their names; inside the app, `CFBundleVersion` still
carries it.

## One build, promoted

Only the pre-alpha step compiles. Each promotion copies that same IPA to the next channel, so
testers on Alpha run the file that was tried on Pre-alpha, and Beta runs the file the Gym scored.

1. **Pre-alpha, automatic.** Every merge into `main` runs `.github/workflows/prealpha.yml`: one
   macOS job builds the external IPA, tags `app-<VERSION>-prealpha.<N>` and replaces the files of
   `app-prealpha-latest`. Its artifact is kept 90 days for later promotions.
2. **Alpha, after approval.** Actions > Promote to Alpha > Run workflow (`promote-alpha.yml`), with a
   pre-alpha tag or empty for the current one. It runs the alpha tests on that commit (`ios-app.yml`:
   PokiCore and loopback tests, in-process field, apps and idle-cycle checks, simulator smoke test,
   agent chat end to end; Poki Setup's core tests), then waits for approval in `alpha`, tags `app-<VERSION>-alpha.<N>` and puts the
   pre-alpha's IPA and Poki Setup files into `app-alpha-latest`.
3. **Beta, by PR.** Actions > Propose promotion > beta (`propose-promotion.yml`), with an alpha tag or
   empty for the current Alpha. The Poki Release Bot opens a PR that adds the promotion to
   `.github/channels.json` and moves `native/ios-app/VERSION` to the next patch version. The PR's
   `promotion gate` check (`promotion-gate.yml`) runs the Gym on that commit and passes when neither
   scorecard has more failures than the last beta's. Merging waits for approval in `beta`, then publishes `app-X.Y.Z-beta.K`
   (`publish-promotion.yml`) with the scorecards attached, and creates `release/X.Y` on a version's
   first beta.

   Promotions only move the patch version. To start a new minor version (0.3.x to 0.4.0), the
   repository owner merges a PR that sets `native/ios-app/VERSION` to it; the pre-alpha built from
   that merge is the first build of the new version, and later promotions bump its patch as above.
4. **Stable, by PR.** Propose promotion > stable, with a beta tag or empty for the newest beta. The
   gate passes once that beta has been out for `soak_days` (3, in `.github/channels.json`) and no
   issue labelled `blocker` is open. To ship sooner, add the `soak-override` label to the PR, or give
   a reason in the proposal's skip field (it is kept in `channels.json`). Merging publishes
   `app-X.Y.Z` after approval in the `stable` environment.

Every publish creates a draft first, checks its file count, then publishes. Releases carry
`Poki-external-<name>.ipa`, `Poki-signing.zip`, `poki-relay-worker.js` (the relay Worker Poki Setup
deploys) and `SHA256SUMS`, plus Poki Setup's `PokiSetup-*` installers and `SHA256SUMS-desktop.txt`.

## Installed clients

A Poki or Poki Setup that is already installed picks its update with the code it shipped with, so a
release has to suit that code as published. Two of its rules decide the layout. Both are in every
Poki published so far and in Poki Setup 0.2.2 (661).

- **The file name is the build.** The picker reads the version and build from the IPA's name
  (`installable` in `desktop/core/src/release.rs`). Poki on the iPhone installs an update only once
  the copy it signed reports that same version and build (`updateNotReady` in
  `native/ios-app/Poki/Signing/SelfSigner.swift`). A Beta's `Poki-external-0.4.0-beta.1.ipa` is
  offered as build `beta.1`, the signed copy reports its number, and Install never starts. Poki
  Setup's Renew has no such check and installs the file.
- **One `Poki-signing.zip` per tag.** `fetch` keeps downloads in a folder named after the release
  tag and uses a `Poki-signing.zip` that is already there. On a rolling tag, a new build is signed
  with the entitlements cached from an earlier one. This is harmless while the entitlements do not
  change; `publish-compat.sh` prints a digest to compare.

Until people have a Poki without these rules, a Beta gets two more releases, made by hand from the
same Pre-alpha files:

| Release | Tag | Made | Picked by |
| --- | --- | --- | --- |
| The Alpha, on its own | `app-X.Y.Z-alpha.N`, the tag Promote to Alpha made | after Promote to Alpha | Alpha users, in place of the rolling release (same build, published later) |
| The Beta, under its build number | `ios-beta-X.Y.Z-N` | public just before the Beta is approved | Stable and Beta users, in place of `app-X.Y.Z-beta.K` (a build number sorts above `beta.K`) |

Both carry `Poki-external-X.Y.Z-N.ipa`, `Poki-signing.zip`, `poki-relay-worker.js` and `SHA256SUMS`.
`scripts/release/publish-compat.sh` makes them in three steps:

1. `check` (the default) downloads the Pre-alpha run's files and verifies them. Run it before
   Promote to Alpha too: it prints the digest of the entitlements in `Poki-signing.zip`, and a
   changed digest has to be known before a rolling tag hands the new build to clients that cached
   the old zip.
2. `draft` uploads a draft release, which no client can see.
3. `public --confirm <tag>` checks the draft again, file by file, against the same Pre-alpha files,
   and only then makes it public. A draft with a file missing, a file from another build or another
   title stays a draft: delete it and run `draft` again. Without `--confirm` it prints the tag and
   the files and publishes nothing.

`draft` and `public` are not behind an environment approval. Only the repository owner runs them, or
someone the owner has told to for that build; agents do not, and a draft that exists is not that
permission. Releases of a later version sort above both. A Stable's `Poki-external-X.Y.Z.ipa` is
offered with an empty build and will need the same second release; the script does not make that
one yet.

To take a Beta back, return `app-X.Y.Z-beta.K` to a draft first and `ios-beta-X.Y.Z-N` second. In
the other order Stable and Beta users are offered the beta-named file alone and stay on an update
they cannot install. Afterwards all three channels fall back to the Alpha, which is the same build:
taking releases back does not take a build away from people, and a Poki that installed it does not
go back. A bad build is replaced by publishing a newer one.

Before publishing, `node scripts/release/first-hop-check.mjs <plan> --build N` prints what Poki 0.3.1
and Poki Setup 0.2.2 (661) pick on each channel after every step of a plan in
`scripts/release/plans/`, and fails when a channel ends on another build or on an update it cannot
install. `--live` reads today's releases from GitHub in place of the saved copy; with
`plans/as-published.json` it shows where a release stands after each real publish.
`plans/withdraw-beta.json` replays taking a Beta back.
`scripts/release/oracle.sh` runs the picker cut from the `app-0.3.1-alpha.752` source over the same
releases and fails when the script's port of it answers differently.

## Branches

- `main`: protected trunk; PRs only. Every merge is a pre-alpha.
- `dev/<topic>`: one change, one PR into `main`, deleted on merge.
- `release/X.Y`: from a version's first beta; takes cherry-picked fixes from `main` for later betas
  and X.Y.Z hotfixes.
- `promote/<channel>-<version>`: the bot's promotion PRs.

## Checks

`pr-checks.yml` runs on every PR into `main` or `release/**`, on Linux only so it never takes one of
the 5 macOS runners: Poki Setup's core tests, the Rust lockfiles, and the workflows (actionlint).

## Setup (once)

- A GitHub App for the bot (Contents, Pull requests and Workflows read and write; Actions and Checks
  read), installed on this repository, with its id and private key in the Actions secrets
  `POKI_BOT_APP_ID` and `POKI_BOT_PRIVATE_KEY`.
- Labels `promotion`, `soak-override` and `blocker`.
- The `alpha`, `beta`, and `stable` environments are configured with `JosssphZhou` as the only
  required reviewer and administrator bypass disabled. Self-review prevention is off so the owner
  can approve a run they started. Agents must not approve on the owner's behalf.
  See [GitHub's environment setup](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).
- Branch protection on `main`: the `PR checks` jobs and `promotion gate / verdict` as required checks.

## Fallback

`channel-release.yml` still builds from a pushed alpha or pre-alpha tag
(`native/ios-app/scripts/cut-release.sh`). Its publish job uses `alpha` only for alpha tags. Pre-alpha tags publish without environment approval.
It starts with cold caches (about 20 minutes) and will be
removed once the pipeline above has shipped a few builds.

App releases can be marked Latest, for example a Beta published as a full release. The Mac
server's update notice (`src/update-check.mjs`) only understands Poki MCP's `vX.Y.Z` tags, and links
to Poki MCP's prebuilt package name its `vX.Y.Z` release instead of `releases/latest`.

## Approval coverage

Publishing Alpha, Beta, Stable, or uploading installers requires the repository owner's approval.
The two Promote to Alpha workflows use `alpha`. The tag fallback selects `alpha` for Alpha and no
environment for Pre-alpha. Main Pre-alpha builds and publishes automatically without approval.
Beta and Stable use their respective environments in `publish-promotion.yml`.
The Windows installer job uses `stable`, including artifact-only runs, because its optional release
upload shares the build job. The macOS installer workflow only uploads Actions artifacts.

These rules protect the workflows that reference the environments. Manual Release uploads and
workflow edits remain outside this gate. An agent using the owner's credentials is not a separate
GitHub identity. Keep approval in the owner's hands.

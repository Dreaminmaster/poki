# Release channels

Poki's iPhone builds are published as GitHub Releases on this repository. Poki Setup (the desktop
installer) reads them and lets each person pick a channel in Settings. A channel decides which
releases Poki Setup installs and renews with.

| Channel | Tag | Title | GitHub release | Who it is for |
| --- | --- | --- | --- | --- |
| Stable | `app-X.Y.Z` | Poki v0.3.0 | its own full release (not marked Latest) | everyone |
| Beta | `app-X.Y.Z-beta.K` | Poki v0.3.0 Beta 1 | its own prerelease | testers |
| Alpha | `app-X.Y.Z-alpha.N` | Poki v0.3.0 (712) Alpha | rolling `app-alpha-latest`, prerelease | early testers |
| Pre-alpha | `app-X.Y.Z-prealpha.N` | Poki v0.3.0 (712) Pre-alpha | rolling `app-prealpha-latest`, prerelease | developers |

A channel includes the channels above it: Beta installs the newest Stable or Beta release, Alpha
the newest Stable, Beta or Alpha, and Pre-alpha the newest release of any kind. Poki Setup's own
updates (`desktop-v*`, `desktop-alpha-*` and `desktop-prealpha-*` tags) follow the same channel.
Poki Setup orders versions so that `0.3.0-beta.1 < 0.3.0-beta.2 < 0.3.0 < 0.3.0-712`: a pre-release
suffix sorts below the plain version, a build number above it.

Until November 2026 app releases were tagged `ios-vX.Y.Z`, `ios-vX.Y.Z-beta.K`, `ios-alpha-X.Y.Z-N` and
`ios-prealpha-X.Y.Z-N`; Poki Setup reads both schemes. Poki Setup 0.2.2 and earlier read only the old
ones, so every pre-alpha and alpha is also copied into the old rolling releases `ios-prealpha-latest`
and `ios-alpha-latest`, which carry the Poki Setup update too. That copy stops once those versions
are gone. Betas and stables exist only as `app-*`.

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
4. **Stable, by PR.** Propose promotion > stable, with a beta tag or empty for the newest beta. The
   gate passes once that beta has been out for `soak_days` (3, in `.github/channels.json`) and no
   issue labelled `blocker` is open. To ship sooner, add the `soak-override` label to the PR, or give
   a reason in the proposal's skip field (it is kept in `channels.json`). Merging publishes
   `app-X.Y.Z` after approval in the `stable` environment.

Every publish creates a draft first, checks its file count, then publishes. Releases carry
`Poki-external-<name>.ipa`, `Poki-signing.zip`, `poki-relay-worker.js` (the relay Worker Poki Setup
deploys) and `SHA256SUMS`, plus Poki Setup's `PokiSetup-*` installers and `SHA256SUMS-desktop.txt`.

## Branches

- `main`: protected trunk; PRs only. Every merge is a pre-alpha.
- `dev/<topic>`: one change, one PR into `main`, deleted on merge.
- `release/X.Y`: from a version's first beta; takes cherry-picked fixes from `main` for later betas
  and X.Y.Z hotfixes.
- `promote/<channel>-<version>`: the bot's promotion PRs.

## Preview builds of pull requests

A pull request can be built into an installable preview without merging it, so an unfinished change
is tried on a phone before it reaches any channel.

- **Commission it.** A maintainer adds the `preview` label to the pull request. `pr-preview.yml`
  builds the branch merged with `main`, and builds again on every push while the label stays. Only
  branches in this repository are built, never forks. Removing the label or closing the pull request
  deletes its builds, and each new build replaces the one before. The deleting is done by
  `pr-preview-tidy.yml`, which always runs `main`'s copy and never the pull request's code, so it
  works only once it is on `main`.
- **Where it lives.** A preview is a workflow artifact named
  `Poki-preview-pr<N>-<version>-<build>-<commit>`, kept 14 days. It is not a release, has no tag and is
  on no channel, so nobody on Stable, Beta, Alpha or Pre-alpha receives it. The app shows it as
  `0.3.0 (712) PR 180`.
- **Who can install it.** GitHub hands artifacts only to signed-in users. In Poki, open Build
  Options › GitHub Account, sign in, and turn on Preview Builds. A Preview Build list then appears
  under the release channels. Poki Setup has the same GitHub Account section under the Apple Account
  and the same list under its channel. From the command line: `poki-setup preview sign-in`,
  `poki-setup preview on`, `poki-setup preview 180`, `poki-setup preview none`.
- **Pre-alpha needs the same sign-in.** The Pre-alpha channel is offered only to signed-in GitHub
  users. Without a sign-in, a saved Pre-alpha choice behaves as Alpha.
- **Going back.** Choose None. The next update check follows the release channel again. A preview
  build that was already downloaded and signed is not installed after that: Poki drops it, and the
  signer refuses to install a prepared build that is no longer the one chosen.
- **When GitHub cannot be read.** If the check for the chosen preview fails (no connection, a GitHub
  error, or the request limit), the choice is kept and nothing is installed. Poki and Poki Setup say
  so; try again later. Only a preview that GitHub confirms is gone (its pull request was closed or
  merged, the label came off, or the build expired) sends you back to the channel.

### Trying a preview build on a phone

Do this once per pull request you test, after its preview build has finished (the PR preview run
is green and lists a `Poki-preview-pr<N>-...` artifact).

Poki needs a Poki with the GitHub sign-in on the phone, its Apple Account signed in under Build
Options (to sign the download), and the loopback on (Setup lists it). Without those, use Poki Setup
on a Mac instead (below).

1. **Sign in to GitHub.** Setup › Build Options › GitHub Account › Sign In with GitHub. Tap Copy
   Code and Open GitHub, sign in on github.com, paste the code and approve. Back in Poki the page
   shows your GitHub name.
2. **Turn on preview builds.** On the same page, turn on Preview Builds.
3. **Choose the pull request.** Go back to Build Options. Under Preview Build, choose the PR, for
   example `0.3.1 (762) PR 206`. Newest Preview Build shows the same build.
4. **Install.** Go back to Setup. Under Signing, tap Download and Install Update. Poki downloads,
   signs and installs the preview, closes, and opens again from the notification.
5. **Check.** Setup › Signing › Poki Version shows `<version> (<build>) PR <N>`.
6. **Go back to the channel.** Build Options › Preview Build › None. If a preview update had been
   prepared but not installed, Install Update disappears. The next channel update installs as
   usual.

With Poki Setup on a Mac: Account › GitHub › Sign In with GitHub, then Preview Builds on. On the
Setup page choose the PR under Preview Build, then Install. From the command line:
`poki-setup preview sign-in`, `poki-setup preview on`, `poki-setup preview <N>`, then install or
renew as usual, and `poki-setup preview none` to go back.

What to report: the build line Poki shows, whether the install finished, and any message the
GitHub Account page, Build Options or Setup showed. For a failed GitHub check, also say whether
the choice was still there afterwards.

The sign-in uses GitHub's device flow under a GitHub App that can only read Actions and pull
requests. Its client ID is the `GITHUB_CLIENT_ID` constant in `desktop/core/src/release.rs`
(`POKI_GITHUB_CLIENT_ID` overrides it for development). It is public, not a secret.

## Checks

`pr-checks.yml` runs on every PR into `main` or `release/**`, on Linux only so it never takes one of
the 5 macOS runners: Poki Setup's core tests, the Rust lockfiles, and the workflows (actionlint). Each job runs only when the PR touches what it
checks: a PR with no change under `desktop/` skips the Poki Setup tests, and the Windows sign-in
check runs only for `desktop/core` and its Cargo files. A skipped job counts as passed.

## Setup (once)

- A GitHub App for the bot (Contents, Pull requests and Workflows read and write; Actions and Checks
  read), installed on this repository, with its id and private key in the Actions secrets
  `POKI_BOT_APP_ID` and `POKI_BOT_PRIVATE_KEY`.
- Labels `promotion`, `soak-override`, `blocker` and `preview`.
- A GitHub App for the GitHub sign-in of preview builds: Device Flow enabled, "Expire user
  authorization tokens" off, repository permissions Actions read and Pull requests read, no
  webhook, installed on this repository. Its client ID is `GITHUB_CLIENT_ID` in
  `desktop/core/src/release.rs`.
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

The Mac server's update notice (`src/update-check.mjs`) reads `releases/latest` and only understands
Poki MCP's `vX.Y.Z` tags, so app releases are never marked Latest: Latest stays on Poki MCP's newest
release.

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

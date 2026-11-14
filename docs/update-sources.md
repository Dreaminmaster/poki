# Update sources

Poki, Poki Setup and the checkout installer use Beta. Saved preferences for other channels remain readable but no longer select previews. This change does not publish a release or change the build approval process.

## Configuration

`config/release-source.json` contains the production catalog address at `https://releases.poki.bot/catalog.json` and its 32-byte Ed25519 public key encoded as hexadecimal. A build with both fields empty reports that R2 is not configured and uses GitHub. An unavailable catalog also uses GitHub, so provisioning the address alone does not mean a migration release has been published.

The production catalog address and verification public key belong in this repository file so reviewers can inspect the trust configuration with the code. Rust embeds the file at build time. The Node installer reads it at runtime. Environment variables do not override either value.

Store the catalog signing private key only in GitHub Actions secrets. Never commit it, embed it in a client, or place it in the release configuration. Private test endpoints remain outside the public repository. Creating production R2 resources and publishing a migration build require separate authorization.

The signed envelope has base64 `payload` and `signature` strings. The signature covers the exact decoded payload bytes. The payload contains `schema: 1` and `releases`, using GitHub-compatible release fields. Every asset additionally declares `size` and `sha256`. Assets use the catalog's HTTPS origin beneath `/releases/`. Local loopback HTTP is supported for isolated verification.

## Download and fallback

Read the catalog once for each selection and carry its integrity metadata with the selected release. The IPA and signing archive use that selected snapshot. Desktop and relay lookups select their own snapshots, so publishers must retain historical entries and files. Verify cached R2 files as well as new downloads.

Network errors, timeouts, unavailable objects and server failures may use GitHub. The user sees a source notice. If the catalog cannot be reached, the client discovers Beta on GitHub using its existing release verification. This retains the older GitHub checksum policy, which does not cover every historical signing archive.

If the catalog was verified but an asset cannot be reached, download only that tag and filename from GitHub and enforce the signed size and checksum. Signature errors, unexpected redirects, unsafe paths and integrity failures are terminal for that operation. Do not retry them through an unverified source.

## Migration and withdrawal

Publish all immutable resources before exposing a new signed catalog. Retain the previous catalog and historical resources. Configure the catalog's cache lifetime separately from immutable release assets.

An installed client that only knows GitHub must first receive a migration build through GitHub. Give that build a higher version and numeric build than every eligible installed candidate. Use independently numbered releases and identical artifacts for Beta and the Stable compatibility record. Verify the actual old picker for Stable, Beta, Alpha and Pre-alpha before publishing. Keep existing compatibility endpoints for users who update later.

To stop distribution, restore the last verified catalog and withdraw the bad candidate from discovery through the approved release process. Keep the source address and historical files available. This does not downgrade an installed app. Ship any repair at a higher version or build, preserving the user's signing identity, login and data. A network outage automatically retries through GitHub for that operation; the next check tries R2 again.

Release approval, production source configuration, real-device migration and installation on supported desktop platforms remain separate release gates. Loopback fixtures and download probes do not prove that an installed phone retained its data.

## Publishing an approved Beta

`publish-promotion.yml` copies the already-built IPA using its numeric build filename, publishes GitHub, then calls `publish-r2.yml`. The R2 job uses the existing Beta approval environment and runs on Linux. It never compiles or promotes a preview. A failed mirror can be retried through **Mirror approved Beta to R2**, with the same published tag. A release dispatch still requires the owner's authorization.

The repository needs these Actions secrets:

| Secret | Purpose |
| --- | --- |
| `POKI_RELEASE_SIGNING_KEY` | Ed25519 private key in PKCS#8 PEM format, matching the reviewed public key |
| `POKI_R2_ACCESS_KEY_ID` | Dedicated R2 S3 credential with object read/write access to `poki-releases` |
| `POKI_R2_SECRET_ACCESS_KEY` | Secret for that bucket-scoped credential |
| `POKI_R2_ENDPOINT` | The account's HTTPS R2 S3 endpoint |

Do not use a developer's short-lived Wrangler OAuth token in Actions. The publisher refuses missing credentials, an incorrect signing key, drafts, previews, nonnumeric IPA filenames, and files that differ from GitHub's recorded sizes or digests. It retains previous signed entries and refuses changed bytes under an existing tag. All files are uploaded and downloaded again from the public R2 address before the catalog changes. The previous catalog is retained under `catalog-history/`; publication evidence is retained as the workflow artifact `r2-publication-evidence`.

For an offline preparation check in Actions, supply downloaded public release files, the GitHub release JSON, the reviewed source configuration and the signing secret through the process environment. Local tests use a separate generated key and an isolated configuration. Do not extract the production private key from Actions:

```sh
node scripts/release/publish-r2.mjs --release release.json --assets artifacts --output evidence --previous previous-catalog.json
```

Omit `--previous` only for the first catalog. Without `--publish`, the command writes local evidence and uploads nothing. With `--publish`, it reads and verifies the live previous catalog itself. Publication is serialized by the workflow's `r2-release-catalog` concurrency group. Do not run another writer outside that group.

Use Standard storage. Cloudflare's [free allowance](https://developers.cloudflare.com/r2/pricing/) is account-wide, including storage and monthly request counts. Creating an empty bucket does not reserve that allowance. Check current account usage before each authorized publication, retain historical files, and stop for a decision if the next publication would need paid capacity. Do not enable paid services or delete historical releases to make space. The [custom domain](https://developers.cloudflare.com/r2/buckets/public-buckets/) avoids using the rate-limited development address for production.

## Acceptance without changing the installed phone

A phone already running a preview cannot prove the path from an installed 0.4.0. Keep that installation intact. First replay the old 0.4.0 picker against the final candidate's actual GitHub records and check the numeric IPA filename, embedded build, signing archive, independently numbered tag and each saved channel. This is source and package evidence only. The physical test needs a separately authorized phone that still has 0.4.0, its existing signing identity, login and data. If none is available, record that acceptance as outstanding; do not downgrade, reinstall or change certificates to manufacture the starting point.

The old app discovers the migration through GitHub. Its first hop cannot prove R2 because that binary does not know R2. After migration, verify that only Beta is offered, then exercise R2 discovery and download of an eligible higher build. Keep GitHub compatibility releases for late updaters. Verify the final app version, retained conversation, login and signing identity after reopening it.

For download evidence, retain the exact signed catalog, selected tag, asset names and the workflow's public-download log. The `desktop/core/examples/update-source-probe.rs` program uses the updater without installing anything; its result reports `source`, `source_notice`, version, build and saved-file results. Run it with a fresh isolated `POKI_SETUP_HOME` so cached files cannot stand in for downloads. Retain a transport trace for the R2 host alongside the verified files. A source field alone does not prove that all bytes came from that host.

For a safe outage test on a computer, put only the probe process behind a loopback CONNECT proxy that rejects `releases.poki.bot` with a connection failure and allows the required GitHub hosts. Keep the reviewed URL and key unchanged. Do not change system proxy settings, DNS, the bucket, its domain or the signed catalog. Run once with GitHub blocked and R2 allowed, then once with R2 blocked and GitHub allowed, using separate empty caches. Save the proxy decisions, fallback notice and download result, then close the proxy. An HTTP 403, bad signature or changed file is a different failure and must not be treated as a network fallback.

A phone outage test requires separate permission for a device-specific rule on a dedicated test network. Block only the R2 hostname for that test device, keep GitHub reachable, and remove the rule after the test. Do not disable the public bucket or alter shared network settings. Until that run occurs, a computer download probe does not prove an in-app phone update.

## Internal preview testing

Pre-alpha artifacts and Alpha approval remain internal build stages. Download the artifact for the exact reviewed commit, with its matching `Poki-signing.zip`, and use Poki Setup's explicit local IPA installation flow on an authorized test phone. Reuse the existing Apple Account, team, application identifiers and signing identity; stop if they cannot be preserved. Do not publish that preview in the Beta catalog or restore a user-facing channel selector. Local installation is a preview test, not evidence of the old app's in-app update path.

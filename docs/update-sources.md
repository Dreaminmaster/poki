# Update sources

Poki, Poki Setup and the checkout installer use Beta. Saved preferences for other channels remain readable but no longer select previews. This change does not publish a release or change the build approval process.

## Configuration

`config/release-source.json` contains `url` and `public_key`. The key is the 32-byte Ed25519 public key encoded as hexadecimal. The checked-in configuration is empty. A build with empty configuration reports that R2 is not configured and uses GitHub. Do not describe it as a deployed R2 migration.

The approved production catalog address and verification public key belong in this repository file so reviewers can inspect the trust configuration with the code. Rust embeds the file at build time. The Node installer reads it at runtime. Environment variables do not override either value. Leave both fields empty until production resources are separately approved.

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

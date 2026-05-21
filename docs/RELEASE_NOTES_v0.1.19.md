# Sub2API Status Bar v0.1.19

This hotfix restores administrator monitoring after `v0.1.18` could show a disconnected state with the message that data was missing.

## What's Changed

- Fixes decoding for `GET /api/v1/admin/users/{id}` when the real admin user detail payload does not include `current_concurrency`.
- Keeps selected-user realtime occupied concurrency sourced only from `/api/v1/admin/ops/user-concurrency`.
- Compresses menu bar status text so selected fields stay visible within the safe status-bar length limit while the full summary remains available in the app UI.
- Keeps the macOS status item on variable width so short menu bar summaries do not leave empty space after the popover has opened.
- Moves default token storage out of macOS Keychain into a private local credentials file so ad-hoc signed updates no longer need a fresh Keychain authorization for every changed code hash.
- Adds a project release constraint requiring temporary local app launch verification without replacing the installed app.

## Verification

- `swift test`
- `swift build`
- `VERSION=v0.1.19 ./scripts/package-release.sh`
- `VERSION=v0.1.19 ./scripts/verify-release.sh`
- Temporary app launch from an extracted `/tmp` bundle, without replacing the installed app.

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.19-macOS.zip.sha256
```

# Sub2API Status Bar v0.1.13

This release fixes popover layout issues found after the v0.1.12 visual refresh and improves the empty subscription experience.

## What's Changed

- Fixes the Overview/Settings switcher so the selected tab remains a compact segmented control instead of stretching into the content area.
- Adds a dedicated empty state when the current account has no subscription quota details.
- Keeps the popover from drifting horizontally while open by freezing the menu bar status item width during refresh-driven title updates.

## Verification

- `swift build`
- `swift test`
- `VERSION=v0.1.13 ./scripts/package-release.sh`
- `VERSION=v0.1.13 ./scripts/verify-release.sh`

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.13-macOS.zip.sha256
```

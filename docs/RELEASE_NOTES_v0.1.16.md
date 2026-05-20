# Sub2API Status Bar v0.1.16

This release keeps the menu bar popover focused on one settings surface and makes high-frequency monitoring available when needed.

## What's Changed

- Keeps the Open Console and Quit footer visible on both Overview and Settings in the main popover.
- Extracts the footer into a shared popover component so page changes do not remove primary actions.
- Removes the redundant standalone Settings scene; settings now live only in the menu bar popover.
- Adds one-second refresh interval support in configuration normalization, first-run setup, and Settings.
- Updates test coverage for the new one-second minimum refresh interval.

## Verification

- `swift test`
- `swift build`
- `VERSION=v0.1.16 ./scripts/package-release.sh`
- `VERSION=v0.1.16 ./scripts/verify-release.sh`

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.16-macOS.zip.sha256
```

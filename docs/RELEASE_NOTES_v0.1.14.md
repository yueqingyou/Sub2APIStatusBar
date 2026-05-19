# Sub2API Status Bar v0.1.14

This release adds explicit appearance control while keeping the default aligned with macOS system settings.

## What's Changed

- Adds a Settings > General appearance picker with System, Light, and Dark choices.
- Keeps new and legacy configs on System by default, so the app follows the current macOS Light/Dark Mode setting unless the user overrides it.
- Applies the selected appearance to login, overview, and settings surfaces immediately after saving.
- Updates the custom warm Claude-inspired palette with adaptive light and dark values for backgrounds, cards, tabs, inputs, borders, and text.

## Verification

- `swift test`
- `swift build`
- `VERSION=v0.1.14 ./scripts/package-release.sh`
- `VERSION=v0.1.14 ./scripts/verify-release.sh`

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.14-macOS.zip.sha256
```

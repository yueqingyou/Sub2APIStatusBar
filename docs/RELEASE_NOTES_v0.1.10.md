# Sub2API Status Bar v0.1.10

This release adds an Open at Login setting so the menu bar app can start automatically after the user signs in to macOS.

## What's Improved

- Adds an Open at Login toggle to Settings.
- Uses a user-level LaunchAgent under `~/Library/LaunchAgents`, keeping the feature compatible with macOS 12.
- Persists the preference in the app config and supports `SUB2API_LAUNCH_AT_LOGIN` for first-run setup.
- Detects stale LaunchAgent app paths so an old copied app path is not treated as the active login item.

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.10-macOS.zip.sha256
```

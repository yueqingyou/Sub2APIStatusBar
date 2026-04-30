# Sub2API Status Bar v0.1.9

This release adds direct in-app update installation. Users can now install newer GitHub Releases from the app instead of opening the release page and replacing the app manually.

## What's Improved

- Adds an Install Update action to the update banner and Settings > Updates.
- Downloads the published macOS zip release asset, extracts `Sub2APIStatusBar.app`, and validates the bundle identifier and version before installing.
- Uses an external helper script to quit the running app, replace the app bundle, clear quarantine metadata, and reopen the updated app.
- Keeps Open Release as a manual fallback when direct installation is unavailable or fails.

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.9-macOS.zip.sha256
```

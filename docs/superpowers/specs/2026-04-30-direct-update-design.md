# Direct Update Design

## Goal

Add direct in-app update installation on top of the existing GitHub Releases update checker. Users should be able to install a newer release from the Settings update section or the update banner without manually opening GitHub, downloading the zip, unzipping it, and replacing the app.

## Scope

The updater uses the existing release format for `yueqingyou/Sub2APIStatusBar`: a published GitHub Release with `Sub2APIStatusBar-X.Y.Z-macOS.zip` and `Sub2APIStatusBar-X.Y.Z-macOS.zip.sha256` assets. The app will parse release assets, download the macOS zip asset, extract `Sub2APIStatusBar.app`, validate bundle identifier and version, start an external helper script, quit the current process, replace the current app bundle, clear quarantine attributes, and reopen the app.

## Architecture

`Sub2APIStatusCore` owns release asset decoding and reusable installer primitives so behavior can be unit tested without AppKit. The App target owns UI state, user messaging, and termination/relaunch orchestration. Replacement happens in a detached shell helper because a running macOS app should not overwrite its own bundle in-process.

## Error Handling

If the release has no suitable zip asset, the UI reports that direct update is unavailable and keeps the existing GitHub release link as a fallback. Download, extraction, bundle validation, and helper launch failures are shown in the update status message without deleting the current app. Once the helper starts, the app quits; the helper keeps a backup while replacing and restores the previous bundle if copying fails.

## Testing

Unit tests cover GitHub release asset decoding, macOS zip asset selection, bundle metadata validation, and generated helper script behavior. Release verification continues to run `swift test`, build, package verification, bundle metadata checks, architecture checks, and the GUI launch smoke test before publishing.

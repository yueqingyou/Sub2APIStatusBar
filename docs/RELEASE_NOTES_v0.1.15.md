# Sub2API Status Bar v0.1.15

This release removes the repeated macOS Keychain authorization loop for GitHub-only ad-hoc updates and makes Settings changes apply immediately.

## What's Changed

- Stores access and refresh tokens in one Keychain payload.
- Creates the token Keychain item with shared local access so ad-hoc app updates do not need repeated password approval.
- Keeps ad-hoc release packaging supported by default for GitHub-only distribution without requiring a paid Developer ID certificate.
- Applies Settings changes immediately and removes the Cancel/Save footer.
- Applies language and appearance changes immediately, including the main popover appearance.
- Fixes English Settings text wrapping and relocalizes update status text after language changes.

## Verification

- `swift test`
- `swift build`
- `VERSION=v0.1.15 ./scripts/package-release.sh`
- `VERSION=v0.1.15 ./scripts/verify-release.sh`

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.15-macOS.zip.sha256
```

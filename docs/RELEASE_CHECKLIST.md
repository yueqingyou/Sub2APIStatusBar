# Release Checklist

## Completed

- [x] User-only dashboard flow using non-admin Sub2API endpoints
- [x] Normal users stay on the non-admin dashboard surface
- [x] Admin users get administrator-only monitoring from verified admin API endpoints
- [x] Balance decoding from `/auth/me`
- [x] Daily, weekly, and monthly subscription quota card
- [x] Clear status labels: `OK`, `High Usage`, `Near Limit`, `Disconnected`
- [x] App icon generation and `AppIcon.icns`
- [x] macOS `.app` bundle script
- [x] Release zip and SHA-256 checksum script
- [x] Release verification script that checks the zip from a clean temporary extraction
- [x] Ad-hoc signing for local builds
- [x] Notarization script ready for Apple credentials
- [x] GitHub Actions workflow for tests, builds, and packaged artifacts
- [x] Product-oriented README
- [x] Changelog
- [x] Unit tests for config, API decoding, quota progress, menu bar text, and status labels
- [x] Keychain token storage with legacy config migration
- [x] Automatic token refresh and dashboard retry on expired access tokens
- [x] GitHub Releases update checking with launch-time and manual checks
- [x] Direct in-app update installation from the published macOS zip asset
- [x] Open at Login preference backed by a user LaunchAgent
- [x] Light, dark, and system-matching appearance preference
- [x] GitHub-only ad-hoc release packaging
- [x] Shared Keychain token item to avoid repeated authorization prompts after ad-hoc in-app updates
- [x] Troubleshooting path for stale Swift build cache errors
- [x] macOS 12 and Swift 5.7 compatibility for Intel Mac builds

## Before Public Distribution

- [x] Choose a public version tag, for example `v0.1.18`
- [ ] Optional: build with a Developer ID Application certificate
- [ ] Optional: notarize the app with Apple
- [x] Attach the release zip and checksum to a GitHub Release
- [ ] Add product screenshots or a short demo GIF to the README
- [ ] Decide whether the repository should stay private or become public

## Release Commands

```bash
swift test
swift build
VERSION=v0.1.18 \
./scripts/package-release.sh
VERSION=v0.1.18 ./scripts/verify-release.sh
```

Developer ID signing:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=v0.1.18 \
./scripts/package-release.sh
```

Default packaging is ad-hoc signed for GitHub-only distribution. Auth tokens use a shared Keychain item so app updates do not depend on a stable paid signing identity for repeated local Keychain authorization.

Notarization requires Apple Developer account credentials and is intentionally not automated until those secrets are available in GitHub Actions or the local keychain.

```bash
APPLE_ID="you@example.com" \
TEAM_ID="TEAMID" \
APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=v0.1.18 \
./scripts/notarize-release.sh
```

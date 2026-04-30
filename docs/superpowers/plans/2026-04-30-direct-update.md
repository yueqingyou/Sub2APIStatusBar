# Direct Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add direct in-app installation for newer GitHub Releases and publish it as `v0.1.9`.

**Architecture:** Extend `Sub2APIStatusCore` to decode GitHub release assets and provide an installer that downloads, extracts, validates, and starts a detached self-replacement helper. Extend the App target to surface install progress, trigger the installer, terminate the current app after helper launch, and keep `Open Release` as a fallback.

**Tech Stack:** Swift 5.7, Foundation `URLSession`, `/usr/bin/ditto`, AppKit/SwiftUI, existing bash release scripts.

---

### Task 1: Release Asset Decoding

**Files:**
- Modify: `Sources/Sub2APIStatusCore/UpdateChecker.swift`
- Test: `Tests/Sub2APIStatusCoreTests/Sub2APIStatusCoreTests.swift`

- [ ] Add failing tests that decode a GitHub release payload with `assets`, ensure the `.zip` asset is stored, and ensure `.zip.sha256` is not selected as the install archive.
- [ ] Run `swift test --filter Sub2APIStatusCoreTests/testGithubReleaseDecodesLatestReleasePayload` and confirm compilation fails because asset support does not exist.
- [ ] Add `GitHubReleaseAsset`, store `assets` on `GitHubRelease`, and add `appZipAsset(repositoryName:)`.
- [ ] Run `swift test --filter Sub2APIStatusCoreTests/testGithubReleaseDecodesLatestReleasePayload` and confirm it passes.

### Task 2: Installer Core

**Files:**
- Modify: `Sources/Sub2APIStatusCore/UpdateChecker.swift`
- Test: `Tests/Sub2APIStatusCoreTests/Sub2APIStatusCoreTests.swift`

- [ ] Add failing tests for bundle metadata validation and helper script generation.
- [ ] Run the new installer tests and confirm compilation fails because installer support does not exist.
- [ ] Add `AppUpdateInstaller` with download, extract, validate, script generation, script writing, and helper start methods.
- [ ] Run the new installer tests and confirm they pass.

### Task 3: App UI And Flow

**Files:**
- Modify: `Sources/Sub2APIStatusBar/Sub2APIStatusBarApp.swift`

- [ ] Add update install state to `MonitorViewModel`.
- [ ] Add `installUpdate()` and `installUpdateNow()` to download/extract/validate/start helper, then terminate the app after helper launch.
- [ ] Add `Install Update` buttons to Settings and the update banner, keep `Open Release` as fallback, and show install progress/status text.
- [ ] Run `swift build` and fix compile errors.

### Task 4: Version And Documentation

**Files:**
- Modify: `Sources/Sub2APIStatusCore/UpdateChecker.swift`
- Modify: `scripts/build-app.sh`
- Modify: `scripts/package-release.sh`
- Modify: `scripts/verify-release.sh`
- Modify: `scripts/notarize-release.sh`
- Modify: `.github/workflows/build.yml`
- Modify: `README.md`
- Modify: `docs/RELEASE_CHECKLIST.md`
- Create: `docs/RELEASE_NOTES_v0.1.9.md`

- [ ] Bump version references from `v0.1.8` / `0.1.8` to `v0.1.9` / `0.1.9`.
- [ ] Update README update behavior to say direct update is available when a release asset can be downloaded.
- [ ] Add release notes for direct in-app update installation.

### Task 5: Verification And Release

**Files:**
- Generated: `dist/Sub2APIStatusBar-0.1.9-macOS.zip`
- Generated: `dist/Sub2APIStatusBar-0.1.9-macOS.zip.sha256`

- [ ] Run `git diff --check`.
- [ ] Run `swift test`.
- [ ] Run `swift build`.
- [ ] Run `VERSION=v0.1.9 ./scripts/package-release.sh`.
- [ ] Run `VERSION=v0.1.9 ./scripts/verify-release.sh`.
- [ ] Verify Info.plist version, minimum OS, binary architecture, and `LC_BUILD_VERSION`.
- [ ] Run `open -n dist/Sub2APIStatusBar.app; sleep 4; pgrep -fl Sub2APIStatusBar; pkill -x Sub2APIStatusBar`.
- [ ] Commit with a short title-style message.
- [ ] Tag `v0.1.9`, push commit and tag, and create GitHub release `Sub2API Status Bar v0.1.9` with zip and checksum assets.

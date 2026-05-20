# Changelog

## v0.1.16

- Keep the Open Console and Quit footer visible on both Overview and Settings inside the popover.
- Remove the redundant standalone Settings scene so settings are managed only from the menu bar popover.
- Allow one-second refresh intervals across config normalization, login setup, and Settings controls.

## v0.1.15

- Store access and refresh tokens in one Keychain item to avoid duplicate authorization prompts.
- Create the token Keychain item with shared local access so ad-hoc GitHub updates do not require repeated macOS password approval.
- Keep ad-hoc release archives supported by default for GitHub-only distribution.
- Apply settings immediately without Cancel/Save buttons, including language and appearance changes.
- Fix English settings text wrapping and refresh localized update status text after language changes.

## v0.1.14

- Added a Light/Dark/System appearance setting that defaults to matching the current macOS appearance.
- Applied the selected appearance to both the login and monitoring popovers immediately after saving.
- Reworked the warm Claude-inspired palette into adaptive light and dark variants so custom cards, fields, tabs, and backgrounds change with the selected mode.

## v0.1.13

- Fixed the Overview/Settings switcher so the selected tab no longer expands into an oversized panel.
- Added a clear empty state for accounts that have no subscription quota details.
- Stabilized the popover anchor while open by freezing the menu bar status item width during refresh-driven title updates.

## v0.1.12

- Refined the menu bar popover with a warmer Claude-inspired visual theme and localized Chinese defaults.
- Moved overview and settings into one unified popover with full-width tab hit targets.
- Added a default account avatar and improved settings layout, footer actions, and update messaging.
- Reduced SwiftUI rendering overhead by removing heavy blur/shadow effects, stabilizing metric identifiers, and avoiding no-op settings draft updates.

## v0.1.11

- Fixed direct update installs that could remain stuck at `Installing update` when the running app did not exit promptly.
- Added update installer logging to help diagnose replacement and restart failures.
- Added regression coverage for self-replacement when the old app process must be terminated before replacing the bundle.

## v0.1.10

- Added an Open at Login setting backed by a macOS 12-compatible user LaunchAgent.
- Persisted the launch-at-login preference with the rest of the app settings.
- Added test coverage for launch-at-login config persistence and LaunchAgent generation.

## v0.1.9

- Added direct in-app update installation from GitHub Releases.
- Validated downloaded update app bundles before replacement.
- Kept Open Release as a fallback when direct installation is unavailable.

## v0.1.8

- Updated fast-mode detection for recent Sub2API service tier values.
- Stopped showing `No Fast` in the menu bar when fast mode is not active.
- Removed the leading healthy checkmark icon when menu bar text is enabled and visible.

## v0.1.5

- Fixed a macOS 12 launch crash caused by creating the menu bar status item before AppKit finished initializing.
- Added a menu bar title fallback when a system symbol is unavailable on older macOS versions.

## v0.1.4

- Lowered the app runtime target to macOS 12 for Intel Mac compatibility.
- Lowered the local development toolchain requirement to Swift 5.7.
- Migrated tests from Swift Testing to XCTest for Xcode 14.2 compatibility.

## v0.1.3

- Added GitHub Releases update checking.
- Added a silent launch-time update check and manual Settings > Updates check.
- Added an in-app update banner when a newer release is available.
- Added semantic version comparison and release payload tests.

## v0.1.2

- Added automatic access-token refresh on `401` responses when a refresh token is available.
- Retried the user dashboard refresh after successful token renewal.
- Added test coverage for unauthorized-response classification.

## v0.1.1

- Moved login tokens to the macOS Keychain with automatic migration from older config files.
- Added a settings action to disconnect and clear saved credentials.
- Added account identity display and model-usage progress bars.
- Removed remaining admin-mode client surface from the user-focused app.
- Removed the unfinished language picker until localization is implemented.
- Added Swift build-cache troubleshooting and cleanup script.
- Added release archive verification script for checksum, zip, plist, and signing checks.
- Added a notarization script for Developer ID signed releases.

## v0.1.0

- Added native macOS menu bar monitor for Sub2API user usage.
- Added first-run login, manual token setup, and local config storage.
- Added user dashboard cards for balance, API keys, requests, costs, tokens, performance, and latency.
- Added subscription quota cards with daily, weekly, and monthly limits.
- Added model distribution and seven-day token trend.
- Added optional menu bar text summary.
- Added generated app icon, app bundle build script, release zip packaging, checksum generation, and GitHub Actions build workflow.

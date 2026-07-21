# Changelog

## v0.1.34

- Reworked the popover into a restrained macOS glass interface with adaptive light and dark surfaces, consistent continuous corners, SF Symbols, and lightweight custom controls across Overview, Accounts, Tasks, Settings, login, empty, loading, and update states.
- Fixed System appearance mode so SwiftUI, the AppKit popover, its hosting view, the active window, semantic colors, and material surfaces use one resolved Light or Dark appearance and update when macOS changes appearance.
- Reduced Settings page switching overhead by isolating it from unrelated high-frequency monitor updates, deduplicating the state it actually consumes, replacing batches of native toggles, and avoiding hidden page trees.
- Reduced repeated task-console and OpenAI quota chart work by preparing stable presentation rows and chart series once per render pass while preserving the existing monitoring and quota contracts.
- Added project-level UI constraints covering SF Symbol fallbacks, status-label geometry, coherent appearance propagation, and long-page rendering performance.

## v0.1.33

- Fixed the menu bar reasoning-effort cell width so `XHigh` is displayed completely instead of being truncated.
- Kept shorter reasoning-effort values compact through the existing measured, stepped adaptive-width layout.
- Added regression coverage for the `GPT-5.6-Sol` and `XHigh` menu bar combination and synchronized related layout assertions.

## v0.1.32

- Added an opt-in request type menu bar item backed strictly by the latest usage record's `request_type`, with `SSE`, `WS`, `Sync`, `Unknown`, and `No` states.
- Exposed the request type setting to both user and administrator monitoring modes without changing the default menu bar selection.
- Preserved raw request type values in the menu bar tooltip and avoided ambiguous inference from the legacy `stream` flag.
- Capitalized compact reasoning effort values and unavailable service tier labels for consistent menu bar presentation.
- Added regression coverage for configuration persistence, user/admin visibility, request type mapping and ordering, tooltip diagnostics, fallback rejection, and the complete administrator menu bar layout.

## v0.1.19

- Fixed administrator monitoring disconnecting after v0.1.18 when `/api/v1/admin/users/{id}` returns the real admin user detail payload without `current_concurrency`.
- Kept selected-user realtime concurrency sourced only from `/api/v1/admin/ops/user-concurrency`.
- Compressed menu bar status text so selected items remain visible within the safe status-bar length limit.
- Kept the menu bar status item on variable width so short summaries no longer leave empty space after the popover has opened.
- Moved default token storage out of macOS Keychain into a private local credentials file to avoid repeated authorization prompts for ad-hoc signed updates.
- Added release verification guidance requiring temporary local app launches without replacing the installed app.

## v0.1.18

- Fixed administrator monitoring so balance, requests, spend, tokens, latest request metadata, trend, model distribution, and subscriptions all use the selected user's verified admin API data.
- Kept realtime occupied concurrency and normal account count as administrator-only metrics from verified admin endpoints.
- Hid selected-user realtime RPM in administrator mode until Sub2API provides a verified user-filtered realtime RPM contract.
- Limited menu bar text length with tooltip/detail access to the full summary to avoid obscuring the macOS menu bar.
- Improved popover focus and admin monitored-user picker behavior.
- Added regression coverage for selected-user admin endpoints, admin subscriptions, admin-only menu bar items, and strict menu bar truncation.

## v0.1.17

- Added administrator-only monitoring for a selected user's realtime occupied concurrency.
- Added administrator-only normal account count display from `/api/v1/admin/dashboard/stats`.
- Kept normal user accounts on the existing dashboard and hid administrator-only menu bar items.
- Documented the verified admin API endpoints and tightened project constraints around Sub2API contract evidence.

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

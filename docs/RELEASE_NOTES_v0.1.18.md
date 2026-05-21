# Sub2API Status Bar v0.1.18

This release fixes administrator monitoring so selected-user metrics are no longer mixed with the logged-in administrator account's own user dashboard data.

## What's Changed

- Reads selected-user balance, usage totals, latest request metadata, trend, model distribution, and subscriptions through verified administrator endpoints filtered by monitored user ID.
- Keeps realtime occupied concurrency sourced from `/api/v1/admin/ops/user-concurrency` and normal account count sourced from `/api/v1/admin/dashboard/stats`.
- Hides realtime RPM in administrator mode because the current verified admin contract does not expose selected-user realtime RPM.
- Caps menu bar text length and keeps the full summary available through the tooltip/detail UI.
- Improves first-run login focus and the administrator monitored-user picker layout.
- Adds regression tests for selected-user admin API paths, admin subscriptions, administrator-only menu bar fields, and strict menu bar truncation.

## Verification

- `swift test`
- `swift build`
- `VERSION=v0.1.18 ./scripts/package-release.sh`
- `VERSION=v0.1.18 ./scripts/verify-release.sh`

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.18-macOS.zip.sha256
```

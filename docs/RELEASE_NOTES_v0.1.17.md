# Sub2API Status Bar v0.1.17

This release adds administrator-only monitoring while keeping normal user accounts on the existing user dashboard.

## What's Changed

- Adds an Admin Monitoring settings section for logged-in admin accounts to choose the user being monitored.
- Shows realtime occupied concurrency for the selected monitored user from `/api/v1/admin/ops/user-concurrency`.
- Shows normal account count from `/api/v1/admin/dashboard/stats`.
- Keeps realtime concurrency and normal account menu bar items hidden for normal user accounts.
- Documents the verified Sub2API admin contracts and keeps `/Users/yuesir/Documents/Project/sub2api` as read-only contract evidence.

## Verification

- `swift test`
- `swift build`
- `VERSION=v0.1.17 ./scripts/package-release.sh`
- `VERSION=v0.1.17 ./scripts/verify-release.sh`

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.17-macOS.zip.sha256
```

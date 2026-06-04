# Sub2API Status Bar

Sub2API Status Bar is a macOS menu bar companion for Sub2API users. It keeps daily spend, token usage, quota pressure, model distribution, and subscription limits visible without keeping the web dashboard open.

## Highlights

- Native macOS menu bar app with a compact SwiftUI popover
- User dashboard cards for balance, API keys, requests, spend, token totals, RPM/TPM, and response time
- Admin accounts can monitor a selected user's realtime occupied concurrency and normal account count in supported views and menu bar fields
- Codex task monitoring through local and remote hooks, keyed by `node_id`, `session_id`, and `turn_id`
- Subscription quota card with separate daily, weekly, and monthly progress bars
- Seven-day token trend and model distribution
- Optional fixed-cell two-row menu bar text summary with value labels, including `T` / `F` Fast state and task status counts
- First-run login and optional manual Bearer token setup
- Optional Open at Login setting for starting the menu bar app automatically after signing in
- Light, dark, and system-matching appearance modes
- Private local credential storage with legacy Keychain migration; no telemetry or third-party analytics
- GitHub Releases update checking from Settings

## Requirements

- macOS 12 or later
- Swift 5.7 or later for local development
- A Sub2API server with user API endpoints enabled

## User API Endpoints

The app expects a Sub2API server with `/api/v1` endpoints:

- `POST /api/v1/auth/login`
- `GET /api/v1/auth/me`
- `GET /api/v1/subscriptions/summary`
- `GET /api/v1/usage`
- `GET /api/v1/usage/stats`
- `GET /api/v1/usage/dashboard/stats`
- `GET /api/v1/usage/dashboard/trend`
- `GET /api/v1/usage/dashboard/models`

Requests send `Authorization: Bearer <token>` after login or manual token setup.

## Admin Monitoring

When the logged-in Sub2API account has the `admin` role, the app uses that same token to enable administrator-only monitoring. Settings shows an **Admin Monitoring** section where the admin can choose which user to monitor. Normal user accounts keep the standard user dashboard and do not see administrator-only menu bar items.

Administrator-only metrics use these real Sub2API admin endpoints:

- `GET /api/v1/admin/users`
- `GET /api/v1/admin/users/{id}`
- `GET /api/v1/admin/ops/user-concurrency`
- `GET /api/v1/admin/accounts?page=1&page_size=1&status=active&lite=true`
- `GET /api/v1/admin/usage`
- `GET /api/v1/admin/usage/stats`
- `GET /api/v1/admin/dashboard/trend`
- `GET /api/v1/admin/dashboard/models`
- `GET /api/v1/admin/users/{id}/subscriptions`

Realtime concurrency means the selected user's occupied concurrency slots from `/api/v1/admin/ops/user-concurrency`. Normal account count comes from the `total` field of `/api/v1/admin/accounts?page=1&page_size=1&status=active&lite=true`, matching the admin account list's **Normal** filter and excluding rate-limited or temporarily unschedulable accounts. Selected-user usage, latest request metadata, trend, model distribution, balance, and subscriptions are read through administrator endpoints filtered by the monitored user ID, not from the administrator account's own `/usage/*` endpoints.

Realtime concurrency can be enabled as an administrator-only menu bar field. It is a gateway occupied-slot signal, not a Codex task identity source; menu bar task status remains hook-only so it can stay precise to `session_id` and `turn_id`.

## Codex Task Monitoring

The app can monitor Codex task state without acting as a Codex client and without controlling Codex. It runs a local `127.0.0.1:<local_port>` HTTP receiver for hook events. Local Codex hooks post directly to that receiver. Remote nodes post to their remote loopback port, and SSH remote forwarding sends those events back to the local receiver.

Node setup is available from the Codex nodes page in the popover. Local and remote nodes are registered independently by node ID: you can keep only a local node, only one or more remote nodes, or a local node plus multiple remote nodes. The app can prepare and install hook sender files, node config, and managed user-level Codex `config.toml` hooks. Remote node forms only ask for SSH connection settings and can be filled manually or prefilled from the local user's `~/.ssh/config` Host entries; node ID, name, local receiver, remote forwarding port, and secret are generated and saved by the app. For Codex home resolution, local nodes prefer the current process `CODEX_HOME`; remote nodes read both remote `CODEX_HOME` and `HOME` through SSH, use `CODEX_HOME` when set, and otherwise fall back to the remote user's `HOME/.codex`. Before writing hooks, the app shows a diff preview and requires confirmation.

The task console shows hook-reported `node_id`, `session_id`, `turn_id`, and current status. Each task keeps a collapsible Event Timeline for recent hook events and raw JSON diagnostics; the expanded event count is configurable in Settings. Received task activity is persisted under the app's Application Support directory so quitting and reopening the app keeps the last known hook-derived task state. Gateway usage data remains supplementary for request, cost, token, User-Agent, and load details; it is not used to infer Codex session or turn identity.

To validate local Codex monitoring, save a local node, preview the hooks diff, confirm the install, then open Codex and run `/hooks`. Trust the `Sub2APIStatusBar task monitor` command hooks shown by Codex, and start a real Codex turn. The node should leave `waitingForTrust`, the task console should show the real `node_id`, `session_id`, and `turn_id`, and the menu bar task item should move through `R` while the turn is active and `D` after it stops.

The Test Event button only validates that the receiver can accept a signed event for the node. For remote nodes, Test Event first starts and confirms SSH-R when needed, then validates that the SSH-R path from the remote loopback port back to the local receiver works. Test events do not prove that Codex has trusted or executed the hooks, and they are not treated as precise task monitoring.

To validate remote Codex monitoring, save a remote node with SSH settings, preview and confirm the remote hooks install, confirm that the post-install remote Test Event reaches the local receiver through SSH-R, then run `/hooks` in Codex on that remote node and trust `Sub2APIStatusBar task monitor`. After a real remote Codex turn, the local task console should show the remote node's real `session_id` and `turn_id`; no public hook receiver is required.

If the Mac is locked without sleeping, macOS or the network may still interrupt an SSH-R tunnel. The app periodically probes the remote loopback-to-local receiver path for running remote tunnels and rebuilds the SSH-R tunnel when the path probe fails. The remote hook sender exits successfully and stays silent when the receiver path is unavailable, so Codex should not be blocked or filled with hook transport errors. This sender behavior is installed on Codex nodes through the hooks writer; after upgrading from an older build, preview and confirm hooks again for each node to replace the already installed sender script. Events that were already received remain visible after app restart. Events emitted while the app is not running or while the SSH-R path is actually down cannot be reconstructed by the app; use the node's **Restart SSH-R** action or the remote Test Event to re-confirm the tunnel, and subsequent real hook events will continue updating the task console.

## Run From Source

```bash
swift run Sub2APIStatusBar
```

On first launch, click the menu bar icon and fill:

- Server URL, for example `https://sub2api.example.com`
- Account email
- Password

Non-secret preferences are saved at:

```text
~/Library/Application Support/Sub2APIStatusBar/config.json
```

Login tokens are stored in a private local credentials file under Application Support with current-user read/write permissions. Existing config files from older builds are migrated automatically on launch, and older Keychain credentials are imported only when macOS allows a no-prompt read.

To switch accounts or remove saved credentials, open Settings and choose **Disconnect**.

Optional first-run environment variables:

```bash
SUB2API_BASE_URL=https://sub2api.example.com \
SUB2API_AUTH_TOKEN=your-token \
SUB2API_SHOW_MENU_BAR_TEXT=true \
SUB2API_LAUNCH_AT_LOGIN=false \
SUB2API_APPEARANCE=system \
SUB2API_MENU_BAR_USAGE_WINDOW=last24Hours \
SUB2API_MENU_BAR_ITEMS=totalCost,model,reasoningEffort,contextLength,fast,rpm \
swift run Sub2APIStatusBar
```

The default appearance follows the current macOS Light/Dark Mode setting. Settings lets users override it to Light or Dark.

When menu bar text is enabled, the status item uses a fixed-cell two-row layout: each enabled item owns a stable cell, adjacent cells are separated by the same vertical divider, the top row shows selected values, and the bottom row shows short labels or compact task counts. The default usage window is **Last 24 Hours**. Settings lets users switch the window to **Today** and choose exactly which fields appear in the status item: total cost, total requests, latest model, reasoning effort, context length, fast status, input price, output price, realtime RPM for normal users, task status, and administrator-only realtime concurrency and normal account count. Enabled fields remain present in the two-row status item; unavailable numeric values use explicit zero, reasoning effort uses `no` when absent or reported as `-`, and model uses explicit "No ..." text rather than placeholder dashes. Codex task counts use a compact persistent `T/R/Q/D/E` row such as `T2R1Q1D0E0`. Context length is derived from the latest usage record as input tokens plus cache creation and cache read tokens; input/output prices follow the web dashboard's cost-detail calculation by deriving price per 1M tokens from cost and token counts.

Admin accounts can additionally enable realtime concurrency and normal account count in the menu bar text. Administrator-only menu bar items are hidden for normal user accounts. Realtime RPM remains a normal-user item because the current administrator usage endpoints do not provide a selected-user realtime RPM contract.

## Build A macOS App

```bash
VERSION=v0.1.22 ./scripts/build-app.sh
```

Output:

```text
dist/Sub2APIStatusBar.app
```

The build script generates the app icon, copies bundle resources, and applies ad-hoc signing by default. This is suitable for GitHub-only distribution when you do not need Apple notarization.

Release builds are host-native. Building on an Intel Mac produces an `x86_64` app bundle.

Optional signed build:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=v0.1.22 \
./scripts/build-app.sh
```

## Package A Release

```bash
VERSION=v0.1.22 ./scripts/package-release.sh
```

Output:

```text
dist/Sub2APIStatusBar-0.1.22-macOS.zip
dist/Sub2APIStatusBar-0.1.22-macOS.zip.sha256
```

By default, `package-release.sh` creates an ad-hoc signed archive. You can pass a signing identity explicitly if you have one:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=v0.1.22 \
./scripts/package-release.sh
```

For GitHub-only ad-hoc releases, auth tokens are stored outside the macOS Keychain in a private local credentials file. Ad-hoc signatures change their code hash on every rebuild, so Keychain access-control prompts cannot be made stable without a persistent Developer ID or other stable signing identity.

## Notarize A Release

Notarization is optional and requires a paid Apple Developer Program membership plus a Developer ID Application certificate. If you do have those credentials, notarize and staple the app with:

```bash
APPLE_ID="you@example.com" \
TEAM_ID="TEAMID" \
APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=v0.1.22 \
./scripts/notarize-release.sh
```

## Updates

The app checks GitHub Releases once on launch and lets users check manually from Settings > Updates. When a newer release is available, the popover shows a small update banner with an Install Update action that downloads the macOS zip asset, replaces the current app bundle, and restarts the app. The GitHub release link remains available as a manual fallback.

GitHub only exposes published releases through the public latest-release API. Draft releases are intentionally not shown to users.

## Development Checks

```bash
swift test
swift build
./scripts/package-release.sh
./scripts/verify-release.sh
```

GitHub Actions runs the same checks on `main`, pull requests, tags, and manual workflow dispatches.

## Troubleshooting

If Swift reports that a PCH was compiled with a different module cache path, the project was probably moved or renamed while `.build` still points at the old folder. Clean the local build cache and run again:

```bash
./scripts/clean-build-cache.sh
swift run Sub2APIStatusBar
```

## Privacy

Sub2API Status Bar stores the server URL, display preferences, and refresh interval in the local Application Support config file. Auth and refresh tokens are stored in a separate private local credentials file with current-user read/write permissions; older Keychain credentials are imported only without showing an authorization prompt. It does not send data anywhere except the configured Sub2API server.

## Acknowledgements
Thanks to the [LinuxDo](https://linux.do/) community for the discussions, sharing, and feedback.

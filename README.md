# TokenRouter Monitor

TokenRouter Monitor is a macOS menu bar companion for [TokenFlux/TokenRouter](https://github.com/TokenFlux/TokenRouter). It keeps daily spend, token usage, quota pressure, model distribution, subscription limits, and precise Codex hook activity visible without keeping the web dashboard open. The repository, executable, bundle identifier, and Application Support directory retain the `Sub2APIStatusBar` name so existing installations can update in place.

## Highlights

- Native macOS menu bar app with a compact SwiftUI popover
- User dashboard cards for balance, API keys, requests, spend, token totals, RPM/TPM, and response time
- Admin accounts can monitor a selected user's realtime occupied concurrency and normal account count in supported views and menu bar fields
- Administrator-only OpenAI OAuth account view with five-hour and seven-day quota, standard value, local history, and forecast signals
- Codex task monitoring through local and remote hooks, keyed by `node_id`, `session_id`, and `turn_id`
- Subscription quota card with separate daily, weekly, and monthly progress bars
- Single-metric seven-day token trend and model distribution through TokenRouter's combined snapshot endpoint
- Split fast and slow refresh paths so live usage stays current without repeatedly fetching expensive aggregate data
- Optional bounded adaptive-width two-row menu bar summary with readable model, reasoning-effort, service-tier, quota, and task-status labels
- First-run login and optional manual Bearer token setup
- Optional Open at Login setting for starting the menu bar app automatically after signing in
- Light, dark, and system-matching appearance modes
- Private local credential storage with legacy Keychain migration; no telemetry or third-party analytics
- GitHub Releases update checking from Settings

## Requirements

- macOS 12 or later
- Swift 5.7 or later for local development
- A TokenRouter server with user API endpoints enabled

## User API Endpoints

The app expects a TokenRouter server with `/api/v1` endpoints:

- `POST /api/v1/auth/login`
- `GET /api/v1/auth/me`
- `GET /api/v1/subscriptions/summary`
- `GET /api/v1/usage`
- `GET /api/v1/usage/stats`
- `GET /api/v1/usage/dashboard/stats`
- `GET /api/v1/usage/dashboard/snapshot-v2`

Requests send `Authorization: Bearer <token>` after login or manual token setup.

## Admin Monitoring

When the logged-in TokenRouter account has the `admin` role, the app uses that same token to enable administrator-only monitoring. Settings shows an **Admin Monitoring** section where the admin can choose which user to monitor. Normal user accounts keep the standard user dashboard and do not see administrator-only menu bar items.

Normal users see **Overview**, **Tasks**, and **Settings**. Administrators additionally see **Accounts** between Overview and Tasks. Task activity and node management share the Tasks page and keep independent view state.

Administrator-only metrics use these real TokenRouter admin endpoints:

- `GET /api/v1/admin/users`
- `GET /api/v1/admin/users/{id}`
- `GET /api/v1/admin/ops/user-concurrency`
- `GET /api/v1/admin/accounts`
- `GET /api/v1/admin/accounts/{id}/usage`
- `GET /api/v1/admin/usage`
- `GET /api/v1/admin/usage/stats`
- `GET /api/v1/admin/dashboard/snapshot-v2`
- `GET /api/v1/admin/users/{id}/subscriptions`

Realtime concurrency means the selected user's occupied concurrency slots from `/api/v1/admin/ops/user-concurrency`. Normal account count traverses all active account pages and excludes rows whose `parent_account_id` is non-null instead of trusting the unfiltered pagination total. Selected-user usage, latest request metadata, model distribution, balance, and subscriptions are read through administrator endpoints filtered by the monitored user ID, not from the administrator account's own `/usage/*` endpoints. The admin snapshot request uses `include_stats=false` and `include_trend=false`; selected-user totals come from `/api/v1/admin/usage/stats`, which has an explicit user filter.

The administrator account page includes only root OpenAI OAuth accounts (`platform=openai`, `type=oauth`, and no `parent_account_id`). Spark shadow accounts and all other account types are excluded from display, counts, history, quota, and value aggregation. Official five-hour and seven-day percentages and reset times come from TokenRouter's account usage endpoint. The page also shows subscription expiry and privacy mode when TokenRouter provides them. Window value uses `standard_cost`; the app does not infer an absolute monetary quota from percentage data. Sanitized samples are retained for 30 days in a private Application Support file so resets and forecast confidence can be evaluated across app restarts.

Realtime concurrency can be enabled as an administrator-only menu bar field. It is a gateway occupied-slot signal, not a Codex task identity source; menu bar task status remains hook-only so it can stay precise to `session_id` and `turn_id`.

## Codex Task Monitoring

The app can monitor Codex task state without acting as a Codex client and without controlling Codex. It runs a local `127.0.0.1:<local_port>` HTTP receiver for hook events. Local Codex hooks post directly to that receiver. Remote nodes post to their remote loopback port, and SSH remote forwarding sends those events back to the local receiver.

Node setup is available from **Tasks > Nodes** in the popover. Local and remote nodes are registered independently by node ID: you can keep only a local node, only one or more remote nodes, or a local node plus multiple remote nodes. The app can prepare and install hook sender files, node config, and managed user-level Codex `config.toml` hooks. Remote node forms only ask for SSH connection settings and can be filled manually or prefilled from the local user's `~/.ssh/config` Host entries; node ID, name, local receiver, remote forwarding port, and secret are generated and saved by the app. For Codex home resolution, local nodes prefer the current process `CODEX_HOME`; remote nodes read both remote `CODEX_HOME` and `HOME` through SSH, use `CODEX_HOME` when set, and otherwise fall back to the remote user's `HOME/.codex`. Before writing hooks, the app shows a diff preview and requires confirmation.

The task console shows hook-reported `node_id`, `session_id`, `turn_id`, and current status. Every active task is retained. Completed, failed, and stale tasks are kept for seven days, capped at the newest 200 tasks, and each task retains at most 20 structured timeline events. Raw JSON is available only for the newest three in-memory events and is never written to disk. Task state is persisted asynchronously under the app's Application Support directory using the version 2 archive format; older mixed-session archives are migrated into precise turns on first load. Gateway usage data remains supplementary for request, cost, token, User-Agent, and load details; it is not used to infer Codex session or turn identity.

To validate local Codex monitoring, save a local node, preview the hooks diff, confirm the install, then open Codex and run `/hooks`. Trust the `Sub2APIStatusBar task monitor` command hooks shown by Codex, and start a real Codex turn. The node should leave `waitingForTrust`, the task console should show the real `node_id`, `session_id`, and `turn_id`, and the menu bar task item should move through `R` while the turn is active and `D` after it stops.

The Test Event button only validates that the receiver can accept a signed event for the node. For remote nodes, Test Event first starts and confirms SSH-R when needed, then validates that the SSH-R path from the remote loopback port back to the local receiver works. Test events do not prove that Codex has trusted or executed the hooks, and they are not treated as precise task monitoring.

To validate remote Codex monitoring, save a remote node with SSH settings, preview and confirm the remote hooks install, confirm that the post-install remote Test Event reaches the local receiver through SSH-R, then run `/hooks` in Codex on that remote node and trust `Sub2APIStatusBar task monitor`. After a real remote Codex turn, the local task console should show the remote node's real `session_id` and `turn_id`; no public hook receiver is required.

If the Mac is locked without sleeping, macOS or the network may still interrupt an SSH-R tunnel. The app periodically probes the remote loopback-to-local receiver path for running remote tunnels and rebuilds the SSH-R tunnel when the path probe fails. The remote hook sender exits successfully and stays silent when the receiver path is unavailable, so Codex should not be blocked or filled with hook transport errors. This sender behavior is installed on Codex nodes through the hooks writer; after upgrading from an older build, preview and confirm hooks again for each node to replace the already installed sender script. Events that were already received remain visible after app restart. Events emitted while the app is not running or while the SSH-R path is actually down cannot be reconstructed by the app; use the node's **Restart SSH-R** action or the remote Test Event to re-confirm the tunnel, and subsequent real hook events will continue updating the task console.

## Run From Source

```bash
swift run Sub2APIStatusBar
```

On first launch, click the menu bar icon and fill:

- Server URL, for example `https://tokenrouter.example.com`
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
SUB2API_BASE_URL=https://tokenrouter.example.com \
SUB2API_AUTH_TOKEN=your-token \
SUB2API_SHOW_MENU_BAR_TEXT=true \
SUB2API_LAUNCH_AT_LOGIN=false \
SUB2API_APPEARANCE=system \
SUB2API_MENU_BAR_USAGE_WINDOW=last24Hours \
SUB2API_MENU_BAR_ITEMS=totalCost,model,reasoningEffort,contextLength,fast,rpm \
swift run Sub2APIStatusBar
```

The `SUB2API_*` environment variable names remain stable for upgrade compatibility. They configure TokenRouter Monitor and do not select a legacy API client.

The default appearance follows the current macOS Light/Dark Mode setting. Settings lets users override it to Light or Dark.

Automatic refreshes update live status, selected-user usage, concurrency, and the newest request at the configured interval, with a five-second minimum. Aggregate token trend, model, subscription, user-list, and account-composition data refresh at most once per minute. OpenAI OAuth account usage is sampled every ten minutes while an administrator is signed in. Manual refresh updates all applicable paths immediately.

When menu bar text is enabled, the status item uses a bounded adaptive-cell two-row layout: each enabled item owns a stable-height cell, adjacent cells are separated by the same vertical divider, and widths are measured from the current value and label then rounded to four-point steps within per-item caps. The top row shows selected values, and the bottom row shows short labels or compact task counts. The default usage window is **Last 24 Hours**. Settings lets users switch the window to **Today** and choose exactly which fields appear in the status item: total cost, total requests, latest model, reasoning effort, context length, service tier, input price, output price, realtime RPM for normal users, task status, and administrator-only realtime concurrency, normal account count, five-hour remaining capacity, and seven-day remaining capacity. Enabled fields remain present in the two-row status item; unavailable numeric values use explicit zero, reasoning effort uses `no` when absent or reported as `-`, service tier uses `no` until a latest usage record exists, and model uses explicit "No ..." text rather than placeholder dashes. Known reasoning values use `min`, `low`, `med`, `high`, `xhigh`, and `max`; known service tiers use `Fast`, `Std`, `Flex`, `Auto`, or `Scale`. Readable model names retain identifiers such as `GPT-5.6-Sol` and `Auto Review`, while lossy compact values keep their raw source in the tooltip. Input and output price values do not repeat `i` / `o` prefixes because the lower row already labels them as `In` and `Out`. Codex task counts use a compact persistent `T/R/Q/D/E` row such as `T2R1Q1D0E0`. Context length is derived from the latest usage record as input tokens plus cache creation and cache read tokens; input/output prices follow the web dashboard's cost-detail calculation by deriving price per 1M tokens from cost and token counts.

Admin accounts can additionally enable realtime concurrency, normal account count, five-hour remaining capacity, and seven-day remaining capacity in the menu bar text. The quota items reuse the Accounts page's schedulable OpenAI OAuth capacity totals, including per-plan values when multiple plans are present. Their bounded adaptive-width cells handle values from zero through multi-account percentages above 100%; longer per-plan text is truncated only in the status item and remains complete in its tooltip. Administrator-only menu bar items are hidden for normal user accounts. Realtime RPM remains a normal-user item because the current administrator usage endpoints do not provide a selected-user realtime RPM contract.

## Build A macOS App

```bash
VERSION=v0.1.26 ./scripts/build-app.sh
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
VERSION=v0.1.26 \
./scripts/build-app.sh
```

## Package A Release

```bash
VERSION=v0.1.26 ./scripts/package-release.sh
```

Output:

```text
dist/Sub2APIStatusBar-0.1.26-macOS.zip
dist/Sub2APIStatusBar-0.1.26-macOS.zip.sha256
```

By default, `package-release.sh` creates an ad-hoc signed archive. You can pass a signing identity explicitly if you have one:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=v0.1.26 \
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
VERSION=v0.1.26 \
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

GitHub Actions runs the same checks on `main`, the repository's current default branch, pull requests, tags, and manual workflow dispatches.

## Troubleshooting

If Swift reports that a PCH was compiled with a different module cache path, the project was probably moved or renamed while `.build` still points at the old folder. Clean the local build cache and run again:

```bash
./scripts/clean-build-cache.sh
swift run Sub2APIStatusBar
```

## Privacy

TokenRouter Monitor stores the server URL, display preferences, refresh interval, and sanitized OpenAI quota history in the local Application Support directory. Quota history contains account IDs, plan labels, timestamps, reset boundaries, percentages, request and token totals, and standard value; it does not contain account names, email addresses, credentials, or raw API responses. Auth and refresh tokens are stored in a separate private local credentials file with current-user read/write permissions; older Keychain credentials are imported only without showing an authorization prompt. It does not send data anywhere except the configured TokenRouter server and the loopback hook receiver configured for Codex task monitoring.

## Acknowledgements
Thanks to the [LinuxDo](https://linux.do/) community for the discussions, sharing, and feedback.

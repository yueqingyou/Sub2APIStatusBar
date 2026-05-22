# Sub2API Status Bar

Sub2API Status Bar is a macOS menu bar companion for Sub2API users. It keeps daily spend, token usage, quota pressure, model distribution, and subscription limits visible without keeping the web dashboard open.

## Highlights

- Native macOS menu bar app with a compact SwiftUI popover
- User dashboard cards for balance, API keys, requests, spend, token totals, RPM/TPM, and response time
- Admin accounts can monitor a selected user's realtime occupied concurrency and normal account count
- Subscription quota card with separate daily, weekly, and monthly progress bars
- Seven-day token trend and model distribution
- Optional configurable menu bar text summary, for example `$120.75 · gpt-5.5 · xhigh · 88.4K ctx · Fast · 3 RPM · 2 CC`
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
- `GET /api/v1/admin/dashboard/stats`
- `GET /api/v1/admin/usage`
- `GET /api/v1/admin/usage/stats`
- `GET /api/v1/admin/dashboard/trend`
- `GET /api/v1/admin/dashboard/models`
- `GET /api/v1/admin/users/{id}/subscriptions`

Realtime concurrency means the selected user's occupied concurrency slots from `/api/v1/admin/ops/user-concurrency`. Normal account count comes from `normal_accounts` in `/api/v1/admin/dashboard/stats`. Selected-user usage, latest request metadata, trend, model distribution, balance, and subscriptions are read through administrator endpoints filtered by the monitored user ID, not from the administrator account's own `/usage/*` endpoints.

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

When menu bar text is enabled, the default usage window is **Last 24 Hours**. Settings lets users switch the window to **Today** and choose exactly which fields appear in the status item: total cost, total requests, latest model, reasoning effort, context length, fast status, input price, output price, and realtime RPM. Context length is derived from the latest usage record as input tokens plus cache creation and cache read tokens; input/output prices follow the web dashboard's cost-detail calculation by deriving price per 1M tokens from cost and token counts.

Admin accounts can additionally enable realtime concurrency and normal account count in the menu bar text. These items are hidden for normal user accounts. Realtime RPM remains a normal-user item because the current administrator usage endpoints do not provide a selected-user realtime RPM contract.

## Build A macOS App

```bash
VERSION=v0.1.20 ./scripts/build-app.sh
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
VERSION=v0.1.20 \
./scripts/build-app.sh
```

## Package A Release

```bash
VERSION=v0.1.20 ./scripts/package-release.sh
```

Output:

```text
dist/Sub2APIStatusBar-0.1.20-macOS.zip
dist/Sub2APIStatusBar-0.1.20-macOS.zip.sha256
```

By default, `package-release.sh` creates an ad-hoc signed archive. You can pass a signing identity explicitly if you have one:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=v0.1.20 \
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
VERSION=v0.1.20 \
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

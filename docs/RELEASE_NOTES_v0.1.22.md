# Sub2API Status Bar v0.1.22

This release adds hook-based Codex task monitoring and refines the menu bar and popover UI for persistent multi-item status display.

## What's Changed

- Adds local and remote Codex node setup from the app, including hook diff preview, user-level `CODEX_HOME` resolution, and SSH remote forwarding for remote hook events.
- Tracks Codex task state from signed hook events keyed by `node_id`, `session_id`, and `turn_id`, with persisted task activity after app restart.
- Adds a task console with compact status badges and a collapsible event timeline for hook diagnostics.
- Rebuilds the menu bar text into fixed-width two-row cells so enabled fields stay present without width jitter.
- Adds administrator-only menu bar fields for selected-user occupied concurrency and normal account count while hiding unavailable admin-only controls from normal users.
- Refines the popover into separated overview, nodes, tasks, and settings pages with localized labels and smaller focused components.
- Improves remote SSH-R handling by probing and restarting failed tunnels, while hook senders stay silent when the receiver path is unavailable.

## Verification

- `git diff --check`
- `swift test`
- `swift build`
- `VERSION=v0.1.22 ./scripts/package-release.sh`
- `VERSION=v0.1.22 ./scripts/verify-release.sh`

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.22-macOS.zip.sha256
```

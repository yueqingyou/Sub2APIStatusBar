# Sub2API Status Bar v0.1.12

This release focuses on the menu bar popover experience: visual polish, faster page switching, better default localization, and a unified overview/settings flow.

## What's Changed

- Updates the popover to a warmer Claude-inspired color system with reduced green emphasis.
- Combines Overview and Settings into one popover so settings no longer open as a separate window.
- Expands the Overview/Settings tab hit targets so the full segment is clickable.
- Adds a default account avatar for signed-in users.
- Defaults new and legacy language settings to Simplified Chinese while keeping English available.
- Localizes primary UI labels, update states, menu bar settings, status labels, and account/subscription text.

## Performance

- Removes large blur and shadow composition hotspots from the popover background and cards.
- Uses stable metric identifiers instead of per-render UUIDs.
- Avoids unnecessary settings draft publishes when opening settings or cancelling unchanged edits.
- Disables tab transition animation to reduce perceived switching latency.

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.12-macOS.zip.sha256
```

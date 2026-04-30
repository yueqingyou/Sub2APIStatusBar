# Sub2API Status Bar v0.1.8

This release adapts the menu bar fast-mode indicator to recent Sub2API service tier values and simplifies the status item when menu bar text is enabled.

## What's Improved

- Recognizes updated fast-mode service tier values, including `fast-mode-2026-02-01`.
- Shows `Fast` only when fast mode is actually active; inactive fast state no longer renders `No Fast`.
- Removes the leading healthy checkmark icon when menu bar text is enabled and visible, keeping the status item text-focused.

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.8-macOS.zip.sha256
```

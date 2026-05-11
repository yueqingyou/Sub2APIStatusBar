# Sub2API Status Bar v0.1.11

This release fixes direct update installation so the app can reliably replace and restart itself after downloading a newer GitHub Release.

## What's Fixed

- Fixes a case where clicking Install Update could stay on `Installing update` without automatically restarting.
- The external update helper now waits for the old app to exit, then sends `TERM` and `KILL` as fallbacks before replacing the app bundle.
- The helper now writes an install log to the temporary directory so future replacement failures are diagnosable.
- Adds regression coverage for replacing the target app when the previous process is stuck.

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.11-macOS.zip.sha256
```

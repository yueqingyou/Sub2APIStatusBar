# Sub2API Status Bar v0.1.5

This release fixes a macOS 12 launch crash in the Intel-compatible build. The app now creates its menu bar status item after AppKit has finished initializing and keeps a visible text fallback when an SF Symbol is unavailable on older macOS versions.

## What's Improved

- Fixed the launch-time crash on macOS 12 caused by early `NSStatusItem` creation.
- Added a menu bar fallback title for older macOS symbol availability.
- Keeps the v0.1.4 compatibility work: macOS 12 runtime target, Swift 5.7 development support, XCTest tests, and Intel-native `x86_64` packaging on Intel Macs.

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.5-macOS.zip.sha256
```

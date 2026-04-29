# Sub2API Status Bar v0.1.4

This release adapts the app for Intel Macs running macOS 12. It lowers the runtime target, keeps local release builds host-native, and makes the project buildable with the Swift 5.7 toolchain included in Xcode 14.2.

## What's Improved

- macOS 12 runtime support for Intel Macs.
- Swift 5.7 and Xcode 14.2 compatibility for local development.
- Intel-native `x86_64` release builds when packaged on an Intel Mac.
- XCTest-based unit tests so the current macOS 12 toolchain can run the full test suite.
- Existing v0.1.3 update detection work: GitHub Releases checking, launch-time update detection, manual Settings > Updates check, and in-app update banner.

## Verify The Download

After downloading the zip and checksum:

```bash
shasum -a 256 -c Sub2APIStatusBar-0.1.4-macOS.zip.sha256
```

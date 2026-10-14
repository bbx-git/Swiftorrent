# 0001 SwiftPM package built by script, no Xcode project

## Context
Apps need a repeatable build and install flow that works the same for every app and needs no Xcode project to create or maintain. Swiftorrent already builds this way.

## Decision
The app is a SwiftPM executable (`Package.swift`). `Scripts/build.sh` runs `swift build -c release`, wraps the binary in a `.app` using `App/Resources/Info.plist`, signs it ad hoc and installs it to `~/Applications/`. The app name comes from `CFBundleExecutable`, so the script is identical in every app. macOS only.

## Consequences
- No `.xcodeproj`, no Xcode setup step; Claude can create everything.
- No iOS apps, entitlements or notarization (see `docs/DISTRIBUTION.md` if the app is ever distributed).
- Alternative rejected: committed Xcode project plus inline `xcodebuild` commands. It needs manual Xcode setup per app.

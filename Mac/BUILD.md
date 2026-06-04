# Building Jarvis (macOS)

The Xcode project is generated from [`project.yml`](project.yml) by XcodeGen —
no `.xcodeproj` is committed. Build tooling is pinned so a clean checkout
builds deterministically.

## Prerequisites (one time, on a Mac)

```sh
brew bundle                 # installs mint (+ optional blueutil)
make bootstrap              # installs the pinned XcodeGen (see Mintfile)
```

You need Xcode 15+ (Swift 5.9, macOS 14 SDK).

## Everyday

```sh
make generate              # regenerate JarvisMac.xcodeproj from project.yml
make build                 # Debug build, ad-hoc signed
make test                  # JarvisMacTests + JarvisBrainDaemonTests
```

`make` targets always regenerate the project first, so editing `project.yml`
is the single source of truth.

## Dependencies

`onnxruntime-swift-package-manager` is pinned to an **exact** version in
`project.yml` (not a floating `from:` range). After deliberately bumping it:

```sh
make resolve               # resolves SPM + copies the lockfile to ./Package.resolved
git add Package.resolved   # commit the refreshed lockfile
```

`Package.resolved` is committed at the `Mac/` root for reproducibility. The
copy generated inside the `.xcodeproj` is git-ignored.

> **First-time note:** `Package.resolved` is produced by `make resolve` on a
> Mac and is not present until then. Commit it on first resolve.

## Tests

`xcodebuild test -scheme JarvisMac` runs both unit bundles via the `JarvisMac`
scheme (see `schemes:` in `project.yml`):

- **JarvisMacTests** — host-based (`TEST_HOST` = the app), so the suites
  `@testable import JarvisMac` against the real sources. The app skips its
  live `bootstrap()` under XCTest (`AppEnvironment.isRunningTests`), which is
  what previously hung the runner.
- **JarvisBrainDaemonTests** — the daemon is an executable target and cannot
  be `@testable import`-ed, so `DaemonCoreTests` keeps minimal inline replicas.
  Drift is caught by parity guards
  (`testReplaySafeTypesParityWithRealSource` etc.) that diff the replica
  against the real `DaemonOfflineQueue.swift` source text.

## Release / notarization

1. Fill in [`Signing.xcconfig`](Signing.xcconfig) with your `DEVELOPMENT_TEAM`
   and Developer ID identity (it carries no account values in git).
2. Add real AppIcon artwork:
   ```sh
   ./Scripts/generate-appicon.sh path/to/icon-1024.png
   git add JarvisMac/Resources/Assets.xcassets/AppIcon.appiconset
   ```
3. Build, sign (hardened runtime is on globally), and notarize. The daemon is
   embedded at `JarvisMac.app/Contents/MacOS/JarvisBrainDaemon` and **must be
   signed + notarized alongside the app**:
   ```sh
   make generate
   xcodebuild -project JarvisMac.xcodeproj -scheme JarvisMac \
     -configuration Release -derivedDataPath build/DerivedData archive \
     -archivePath build/JarvisMac.xcarchive
   # codesign --deep is discouraged; sign the daemon explicitly, then the app:
   codesign --force --options runtime --timestamp \
     --entitlements JarvisMac/Resources/JarvisMac.entitlements \
     -s "Developer ID Application" \
     "build/.../JarvisMac.app/Contents/MacOS/JarvisBrainDaemon"
   codesign --force --options runtime --timestamp \
     --entitlements JarvisMac/Resources/JarvisMac.entitlements \
     -s "Developer ID Application" "build/.../JarvisMac.app"
   xcrun notarytool submit ... --wait
   xcrun stapler staple "build/.../JarvisMac.app"
   ```
4. Verify:
   ```sh
   codesign --verify --strict --verbose=2 JarvisMac.app
   spctl -a -vv JarvisMac.app
   ```

The app registers itself as a login item via `SMAppService` on first launch
(`LoginItemManager`) and runs as a menubar (`.accessory`) app — no Dock icon.

## Known remaining gaps (need a Mac / your account)

- **`Package.resolved`** must be generated once via `make resolve`.
- **Signing identity / team** must be supplied in `Signing.xcconfig`.
- **AppIcon artwork** — drop a 1024px source and run the script above.
- **Daemon as `SMAppService.agent`** — the daemon is still managed via the
  hand-rolled `launchctl bootstrap` in `DaemonManager`. Migrating to
  `SMAppService.agent` (bundling the plist under `Contents/Library/LaunchAgents`)
  is a follow-up.
- **`AndroidEventReceiver.buildSignal` WhatsApp branch** is still duplicated in
  `WhatsAppRoutingTests`; sharing the real function needs a behaviour-preserving
  refactor + a real build to verify.

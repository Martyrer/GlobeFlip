# Contributing to GlobeFlip

Thanks for helping. This guide covers building, testing, and submitting
changes.

## Requirements

- Apple Silicon Mac running macOS 26 or newer
- Xcode 26 or newer
- XcodeGen 2.46 or newer (`brew install xcodegen`)

## Build and test

`project.yml` is the source of truth. `GlobeFlip.xcodeproj` is generated and
ignored by git, so regenerate it after pulling or editing `project.yml`:

```sh
xcodegen generate
xcodebuild -project GlobeFlip.xcodeproj -scheme GlobeFlip -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

If `xcodebuild` complains about the active developer directory, point it at
Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Tests use Swift Testing. Pure logic lives in `GlobeFlipCore` and is covered by
`Tests/GlobeFlipCoreTests`. App-layer tests live in `Tests/GlobeFlipAppTests`.

## Architecture

- `Sources/GlobeFlipCore/` is a static framework with no AppKit or CoreGraphics
  event dependencies: tap classification, timing calibration, preferences,
  statistics. Anything testable without a running event tap belongs here.
- `GlobeFlip/` is the app: the CGEvent tap (`GlobeEventMonitor`), input source
  switching (`InputSourceManager`), orchestration (`RuntimeCoordinator`,
  `SwitchCoordinator`), and SwiftUI views.

`SPEC.md` describes the behavior contract. Keep changes consistent with it, or
update the spec in the same pull request.

## Running the app locally

GlobeFlip needs the Input Monitoring permission to observe the Globe/Fn key.
macOS ties that grant to the app's code signature. Debug builds are ad-hoc
signed by default, which produces a new signature on every build, so macOS
forgets the grant after each rebuild.

To keep the grant across rebuilds, sign Debug builds with a stable self-signed
certificate:

1. Open Keychain Access, then Keychain Access > Certificate Assistant >
   Create a Certificate.
2. Name: `GlobeFlip Local Development`. Identity Type: Self Signed Root.
   Certificate Type: Code Signing.
3. Create `Configs/Local.xcconfig` (ignored by git) containing:

   ```
   CODE_SIGN_IDENTITY = GlobeFlip Local Development
   ```

4. Run `xcodegen generate` and build.

Grant Input Monitoring once. It survives until the certificate changes.

Also set System Settings > Keyboard > **Press Fn/Globe key to** to
**Do Nothing**, otherwise macOS consumes the tap before GlobeFlip sees it.

## Pull requests

- Keep each pull request focused on one change.
- Run the full test suite before pushing.
- Add or update tests for behavior changes. Prefer putting logic in
  `GlobeFlipCore` so it can be tested without an event tap.
- Do not add network calls, analytics, logging of typed text, private APIs, or
  new entitlements. See `SECURITY.md`.
- Describe how you verified the change on real hardware when it touches the
  event tap or switching path.

## Releasing

Version 1 uses an ad-hoc-signed, Hardened Runtime ZIP. Select a stable Xcode,
then pin exact Xcode and macOS SDK builds plus GitHub repository:

```sh
EXPECTED_XCODE_BUILD=YOUR_STABLE_XCODE_BUILD_ID \
EXPECTED_SDK_BUILD=YOUR_STABLE_SDK_BUILD_ID \
GITHUB_REPOSITORY=Martyrer/GlobeFlip \
scripts/build-release.sh
```

Outputs under `dist/`:

- `GlobeFlip-<version>-arm64.zip`
- matching `.sha256`
- `globeflip.rb` for the owned Homebrew tap

Ad-hoc builds are not notarized. On first launch from a quarantined download,
macOS should block the app. Use System Settings > Privacy & Security >
**Open Anyway**, then confirm the launch. Do not disable Gatekeeper globally.

Developer ID signing and notarization remain a future distribution upgrade.

## Reporting bugs

Use the bug report issue template. Include macOS version, keyboard model,
enabled input sources, and whether Input Monitoring is granted.

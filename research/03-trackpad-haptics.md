# Trackpad haptic feasibility

> Historical research from July 2026. SPEC.md is authoritative; supported macOS versions and distribution changed later.

Research date: 2026-07-31

## Decision

**Yes, as an optional best-effort enhancement.** Native macOS AppKit exposes the
public `NSHapticFeedbackManager` API, available since macOS 10.11. A menu bar
utility can request the semantic `generic` pattern with immediate timing after
it has confirmed an Input Source switch:

```swift
import AppKit

@MainActor
func playInputSourceSwitchHaptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(
        .generic,
        performanceTime: .now
    )
}
```

This call type-checks against the installed macOS 27.0 SDK. The SDK declares the
manager, performer, patterns, and timing values as public AppKit API, with
`API_AVAILABLE(macos(10.11))`; it marks the API unavailable to Mac Catalyst.
The declarations are in
`AppKit.framework/Headers/NSHapticFeedback.h`.[1][2]

The haptic **must not be part of switching correctness or the only confirmation
of success**. Apple explicitly reserves the right to suppress a request and
gives a Force Touch trackpad not being touched as an example.[3] That condition
is likely during a Globe Tap. Switching must complete normally and observably
whether or not a haptic is produced.

There is one product-fit caveat. Apple says performer calls must respond to a
user-initiated action, which a Globe Tap satisfies, but its macOS HIG describes
the patterns specifically in response to a drag operation or force click.[3][4]
An Input Source switch is therefore technically supported by the API but is
outside Apple's specifically documented Mac interaction examples. Keep the
feature optional, restrained, and subject to hardware UX testing.

## Public API and stability

The current Apple documentation describes `NSHapticFeedbackManager` as the
manager for systems with a Force Touch trackpad.[1] Its
`defaultPerformer` chooses a performer based on the current input device,
accessibility settings, and user preferences. Apple says the input device may
change while the app runs, so the app must request `defaultPerformer` each time
instead of caching it.[5]

The installed macOS 27.0 public header confirms:

- `NSHapticFeedbackManager`, `NSHapticFeedbackPerformer`,
  `NSHapticFeedbackPattern`, and `NSHapticFeedbackPerformanceTime` are available
  on macOS 10.11 and later.
- The API is unavailable to Mac Catalyst.
- The manager exposes no support query, error return, completion callback, or
  intensity control.
- The system may suppress feedback. The header repeats the example that Force
  Touch trackpads do not perform it when the user is not touching the trackpad.

Apple's archived `ForceTouchCatalog` sample demonstrates the Force Touch
trackpad APIs, including performing feedback. Its runtime requirement is OS X
10.11 or later, but Apple labels the 2016 sample as no longer updated, so it is
corroborating history rather than the source of current API behavior.[6]

No current Apple source found a foreground-window, active-application, or
visible-view precondition on `defaultPerformer` or `perform`. The call takes no
view or window. It is therefore reasonable to use it from a native menu bar
utility, but Apple does not explicitly document or certify this exact
background-utility scenario.

## Hardware and settings

Actual output requires a Force Touch-capable Apple trackpad. Apple says most
modern Mac laptops and rechargeable Magic Trackpad models have Force Touch;
Apple trackpads without Force Touch use a mechanical click and do not provide
haptic feedback.[7] The HIG likewise limits Mac haptics to compatible trackpad
hardware.[4]

The user can identify compatible hardware in **System Settings > Trackpad >
Point & Click**: the **Force Click and haptic feedback** option appears only for
a Force Touch trackpad.[7] Apple also notes that available Trackpad settings
depend on the connected Mac or trackpad.[8]

The app must not maintain a model-number allowlist. It must request the current
default performer and accept silence because:

- the active input device can change;
- accessibility settings and user preferences influence the performer;
- the trackpad can be disconnected or powered off;
- the system can suppress individual requests, including when the trackpad is
  not being touched.[3][5][7]

Apple does not document a public AppKit Boolean that predicts whether a specific
request will be felt, nor does it enumerate the exact accessibility and
preference combinations that suppress it.

## Patterns and timing

AppKit provides exactly three trackpad feedback patterns:[2][4]

| Pattern | Documented meaning | Decision |
| --- | --- | --- |
| `generic` | General feedback when the others do not apply | Use for a successful Input Source switch |
| `alignment` | Alignment or boundary reached while dragging | Do not repurpose |
| `levelChange` | Movement between discrete pressure levels | Do not repurpose |

For a post-switch haptic, use `.now`; Apple defines it as immediate feedback
without waiting to synchronize with a screen update.[9] `.default` currently
means the next screen update, and `.drawCompleted` explicitly waits for that
update, so neither fits a utility with no corresponding drawing pass.[9]

AppKit offers no public strength or "subtlety" parameter for these trackpad
patterns. "Subtle" can only mean choosing the generic system pattern, emitting
it once, and avoiding repeated or gratuitous feedback. Apple's HIG says to use
patterns according to their meanings, avoid overuse, complement other feedback,
and make haptics optional.[4]

Core Haptics is not a documented route to custom Force Touch trackpad output.
Although Core Haptics types have macOS availability, Apple's Mac-specific HIG
documents only AppKit's three semantic trackpad patterns.[4] Do not infer that
Core Haptics availability means a Mac trackpad supports custom intensity,
sharpness, transient, or continuous playback.

## Permissions and distribution

The haptic call itself has no documented privacy prompt, TCC authorization,
special entitlement, or user-consent API. Its signature returns `Void` and
reports neither authorization nor playback failure.[2][3] Apple's App Sandbox
resource-access documentation lists gated hardware such as camera, microphone,
USB, printing, and Bluetooth, but no haptic or trackpad-output entitlement.[10]

This is a public AppKit API, satisfying the App Store Review Guideline 2.5.1
requirement to use public APIs.[11] Nothing in the haptic API requires
distribution outside the Mac App Store or disabling App Sandbox. Other parts of
the utility's Globe/Fn interception may have separate permission, entitlement,
or distribution constraints; they do not grant or improve haptic delivery.

Use a native macOS target. The current SDK explicitly excludes this AppKit API
from Mac Catalyst.[2]

## Required implementation contract

1. Expose an app-level haptics preference and default conservatively based on
   product testing; always honor an off setting.
2. Only request feedback after the Input Source switch has succeeded.
3. On the main actor, fetch `defaultPerformer` at the moment of use and perform
   one `.generic` pattern with `.now`.
4. Do not cache the performer, probe private APIs, inspect device model IDs, or
   substitute `alignment`/`levelChange`.
5. Do not retry, block, log silence as an error, or infer that the haptic was
   felt. There is no completion or delivery result.
6. Preserve the exact same switch result, state transition, visual/menu state,
   and latency when the preference is off, hardware is absent, settings suppress
   output, the trackpad is not touched, or the system drops the request.

## Remaining uncertainty

- Apple's general performer guidance permits user-initiated actions, but the
  Mac HIG's concrete scope is drag operations and force clicks. It does not
  explicitly approve keyboard-triggered confirmation haptics.
- Apple provides no exhaustive current hardware model matrix in the API docs;
  its support article uses the broader "most modern Mac laptop computers" and
  "rechargeable models of Magic Trackpad" descriptions.
- Apple does not document a deterministic support/preflight API, which
  accessibility settings suppress output, or whether a specific request was
  delivered.
- The documentation does not explicitly discuss a UIElement/menu-bar-only
  process. Physical testing should cover an inactive menu bar utility, built-in
  and rechargeable Magic Trackpads, the system haptics setting on/off,
  touch/no-touch at Globe release, disconnect/reconnect, and current supported
  macOS releases.

## Research method

Context7 was run first as required. It resolved the high-reputation exact-name
library `/websites/developer_apple_cn`, but the haptics query returned unrelated
UIKit, AuthenticationServices, and ARKit snippets. No Context7 output was used
as evidence. This report instead uses current Apple documentation, Apple Support
material, the installed public SDK headers, and Apple's archived sample.

## Sources

1. [Apple Developer Documentation: NSHapticFeedbackManager](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager)
2. Apple macOS 27.0 SDK,
   `System/Library/Frameworks/AppKit.framework/Headers/NSHapticFeedback.h`,
   lines 15-38 (`NSHapticFeedbackPattern`,
   `NSHapticFeedbackPerformanceTime`, `NSHapticFeedbackPerformer`,
   `NSHapticFeedbackManager`)
3. [Apple Developer Documentation: `perform(_:performanceTime:)`](https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer/perform(_:performancetime:))
4. [Apple Human Interface Guidelines: Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
5. [Apple Developer Documentation: `defaultPerformer`](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/defaultperformer)
6. [Apple Sample Code Archive: ForceTouchCatalog](https://developer.apple.com/library/archive/samplecode/ForceTouchCatalog/Introduction/Intro.html)
7. [Apple Support: How to force click and get haptic feedback on Apple trackpads](https://support.apple.com/en-us/102309)
8. [Apple Support: Change Trackpad settings on Mac](https://support.apple.com/guide/mac-help/change-trackpad-settings-mchlp1226/mac)
9. [Apple Developer Documentation: `NSHapticFeedbackManager.PerformanceTime`](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/performancetime)
10. [Apple Developer Documentation: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
11. [App Review Guidelines, section 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements)

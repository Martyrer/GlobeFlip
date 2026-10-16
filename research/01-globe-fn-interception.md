# Globe/Fn interception on macOS

> Historical research from July 2026. SPEC.md is authoritative; supported macOS versions and distribution changed later.

Date: 2026-07-31

## Decision

The product is feasible on macOS 15 and 26 without a driver, root access, private
API, event suppression, or synthetic key replay, provided onboarding requires
the user to set **Press Fn/Globe key to: Do Nothing** in Keyboard settings.
Apple documents that setting on both supported OS versions, and separately
documents Fn as a public Core Graphics modifier flag.[1][2][3]

Use a listen-only Core Graphics session event tap to observe
`flagsChanged`, `keyDown`, and `keyUp`. Identify a candidate Fn transition from
`kCGEventFlagMaskSecondaryFn` and, subject to hardware validation,
`kVK_Function` (`0x3f`). Classify a Globe Tap only after a clean down/up pair
with no intervening key and before the hold threshold. Because the tap never
changes the event stream, Fn Hold and Fn chords continue to the system without
delay. If observation is unavailable, the utility does nothing.[3][4][5]

Ship the Developer ID build outside the Mac App Store with Hardened Runtime and
notarization, but without App Sandbox. Core Graphics event taps do not declare
a code-signing entitlement; their access is controlled by user-granted privacy
permission. App Sandbox is mandatory for Mac App Store distribution, not for
Developer ID notarization, and Apple exposes no sandbox entitlement dedicated
to cross-application keyboard monitoring.[6][7]

Do **not** make an active event tap, HID seizure, virtual HID device, DriverKit
extension, or private `IOHIDEventSystemClient` filter part of the supported
design. An active session tap is a useful prototype only: Apple documents that
it can delete generic Quartz events, but does not document where the
standalone Globe action occurs relative to that tap or guarantee that replayed
Fn events preserve hardware behavior.[4][5]

## Public mechanisms

| Mechanism | Observe | Suppress | Preserve native Fn | Decision |
| --- | --- | --- | --- | --- |
| Listen-only `CGEventTapCreate` at `kCGSessionEventTap` | Yes | No | Yes, because events are untouched | **Use** |
| Active `CGEventTapCreate` at `kCGSessionEventTap` | Yes | Yes; callback may return `NULL` | Not documented for Globe/Fn replay | Prototype only |
| `NSEvent.addGlobalMonitorForEvents` | Yes, asynchronously | No | Yes | Diagnostic fallback, not core |
| `NSEvent.addLocalMonitorForEvents` | Own app only | Own app dispatch only | Irrelevant globally | Reject |
| `IOHIDManager` / `IOHIDDevice` | Raw device input | Only by seizing the whole device | Requires rebuilding all seized input | Reject |
| `IOHIDUserDevice` | Creates a virtual device | Does not intercept the physical device | Requires a dedicated virtual-device entitlement | Reject |
| DriverKit HID system extension | Device-driver layer | Potentially, for matched hardware | High-risk and hardware-specific | Reject |
| Private/undeclared HID event-filter symbols | Possible | Possible | Unsupported | Reject |

### Core Graphics event taps

Apple describes event taps as either passive listeners or active filters.
Active filters may pass, modify, replace, or discard an event. The public
callback contract says returning `NULL` deletes an event; returning `NULL` from
a passive listener does not affect the stream. The callback runs on the run
loop to which its `CFMachPort` source is attached.[4][5]

Use `kCGSessionEventTap`, not `kCGHIDEventTap`: Apple explicitly reserves the
HID-entry tap location for root. A menu bar utility does not need that location
to observe session keyboard events.[4]

The relevant public event model is:

- `kCGEventFlagsChanged` reports modifier-state transitions.
- `kCGEventFlagMaskSecondaryFn` means Fn is down for a keyboard, mouse, or
  flag-changed event. Apple notes that it is found primarily on laptop
  keyboards.
- HIToolbox declares the layout-independent virtual key
  `kVK_Function = 0x3f`.
- `CGEventTimestamp` is approximately nanoseconds since system startup and can
  measure the gesture without wall-clock changes.[3][8]

The product should use the Fn-mask transition as the semantic signal and treat
the virtual key code as a hardware-tested discriminator, not as an
Apple-documented definition of the Globe key. Apple publishes no separate
Core Graphics `Globe` flag or event type.

### AppKit monitors

Apple says global `NSEvent` monitors receive asynchronous copies, cannot modify
or prevent delivery, omit events sent to the monitoring app itself, and require
Accessibility trust for key-related events. Local monitors can return `nil`,
but only for events dispatched through the utility's own `NSApplication`.
Neither is suitable for global suppression, and the asynchronous global API is
weaker than a Core Graphics tap for the timing-sensitive classifier.[9][10]

### HID APIs

`IOHIDManagerOpen` and `IOHIDDeviceOpen` are public device APIs. Passing
`kIOHIDOptionsTypeSeizeDevice` creates an exclusive link that prevents the
system and other clients from receiving **all** events from the device. That is
not per-key suppression and violates the fail-open requirement if the utility
hangs or crashes.[11]

Apple's public HID usage table does not define a portable Keyboard Fn or Globe
usage. Apple's archived `hidutil` remapping note operates on HID usage-page and
usage pairs, so it does not establish a portable Globe/Fn mapping.[12]
`IOHIDUserDevice` creates a virtual device and explicitly requires
`com.apple.developer.hid.virtual.device`; it does not solve interception of the
physical key.[13]

The current public `IOHIDEventSystemClient.h` declares property and service
inspection only. The IOKit binary exports additional event callback/filter
symbols that are absent from the public header; those are not public API and
must not be linked or resolved dynamically.

Apple's archived HID Explorer and HID Calibrator samples demonstrate generic
HID enumeration, not Globe/Fn interception. No current first-party sample
establishing Globe suppression or replay was found.[14][15]

## Permissions and distribution

### Listen-only design

Call `CGPreflightListenEventAccess()` before installing the tap and
`CGRequestListenEventAccess()` only from an explicit onboarding action. The
headers describe these as checking and requesting event-listening access;
Apple's user guide calls the corresponding privacy capability Input Monitoring
and says it allows an app to monitor keyboard, mouse, or trackpad input while
other apps are in use.[16][17]

Apple does not explicitly map each event-tap option to the System Settings
panel in the API reference. Therefore the signed production bundle must verify
on both macOS 15 and 26 that the listen-only session tap:

1. prompts for or appears under Input Monitoring;
2. receives `flagsChanged`, `keyDown`, and `keyUp` after approval;
3. fails without swallowing input before approval or after revocation.

### Active filtering or posting

Apple's event-tap documentation says key events require assistive-device
access, and the current user guide describes Accessibility permission as
allowing an app to access and control the Mac. Check
`AXIsProcessTrustedWithOptions` for any active-filter experiment.
`CGPreflightPostEventAccess()` and `CGRequestPostEventAccess()` separately
check/request event-synthesizing access on macOS 10.15 and later.[4][18][19]

Do not request Accessibility or posting access in the supported observe-only
design unless another proven requirement needs it. It grants broader control
than Input Monitoring and is unnecessary when events are never changed.

### Signing, sandbox, and notarization

Notarization is an automated malware and code-signing check, not App Review.
Apple requires Developer ID signing, Hardened Runtime, a secure timestamp, and
valid entitlements for modern Developer ID distribution. It does not require
App Sandbox. Conversely, Apple states that Mac App Store apps must be
sandboxed.[6][7]

For the specified direct-distribution product:

- sign with Developer ID Application;
- enable Hardened Runtime and notarize/staple the release;
- leave `com.apple.security.app-sandbox` disabled;
- use no HID, DriverKit, root, setuid, or private-API entitlement;
- treat Input Monitoring/Accessibility as user privacy grants, not embedded
  entitlements.

This keeps the supported path within public user-space APIs. Sandboxed event-tap
behavior was not established by current Apple documentation and is irrelevant
to the chosen distribution target.

## Secure Input

Secure Event Input is a hard boundary, not an error to bypass. Apple's current
HIToolbox header says keyboard input goes only to the focused application while
Secure Event Input is enabled. Apple's archived technical note explicitly
lists event taps and HID seizure as keyboard intercept processes and says the
system stops passing keyboard events to intercept processes whenever any
process enables Secure Event Input.[20][21]

`IsSecureEventInputEnabled()` is public and reports whether any process has
enabled it. The utility must never call `DisableSecureEventInput()` for another
process.[20]

Required behavior:

- if Secure Input is enabled, clear any partial Globe/Fn gesture and do
  nothing;
- accept a Globe Tap only when both edges form a clean sequence observed while
  Secure Input is off;
- reset partial state on tap disablement, permission change, session
  lock/unlock, sleep/wake, keyboard removal, and process shutdown;
- never synthesize a missing down or up edge.

This is fail-open: the focused application continues to receive protected
input, while GlobeFlip simply misses that gesture.

## Fail-open and latency contract

The supported listener must:

- use `kCGEventTapOptionListenOnly` and always return the original event;
- perform only timestamp/state updates in the callback and dispatch input-source
  work off the callback path;
- never wait for the hold timer inside the callback;
- observe tap-health events
  `kCGEventTapDisabledByTimeout` and `kCGEventTapDisabledByUserInput`, clear the
  gesture state, and report/recover without blocking the keyboard;
- create no exclusive HID open and no virtual replacement keyboard;
- disable switching when permission, Secure Input, event identity, or state is
  uncertain.

Apple exposes minimum, average, and maximum event-tap latency in
`CGEventTapInformation`, so development builds can measure callback health.[5]
Apple does not publish a latency guarantee. The acceptance target therefore
needs empirical p50/p95/p99 measurements on the supported matrix.

Requiring **Do Nothing** avoids the race with Apple's own standalone Globe
action. Apple provides no public API for changing that user setting, so
onboarding must show the user how to change it and must not write a private
preference. The utility should also explain how to restore the setting on
disable or uninstall.[1][2]

## Keyboard boundaries

Apple's guides use “Fn key or Globe key” for the same configurable action and
show a Function (Fn)/Globe key on current Magic Keyboard hardware. They also
document holding Fn with a function key for the alternate top-row
function.[1][22]

Support should be capability-based:

- **Supported after validation:** built-in Apple keyboards and Apple Magic
  Keyboards that emit the documented Fn flag transition.
- **Conditionally supported:** external keyboards whose Globe/Fn key produces
  the same Quartz event sequence.
- **Unsupported:** firmware-only Fn keys or vendor keys that produce no public
  Quartz Fn transition.

Core Graphics exposes a keyboard type but no public per-keyboard device ID for
ordinary keyboard events. Simultaneous keyboards therefore share aggregate
modifier state at this layer. Do not promise per-device settings or reliable
attribution. `IOHIDManager` may be used in a diagnostic build to identify
devices, but it does not create a portable Globe identity and must not seize
them.

## macOS support boundary

The supported baseline can be macOS 15 Sequoia and macOS 26 Tahoe on Apple
Silicon:

- Apple publishes the Fn/Globe Keyboard setting, including **Do Nothing**, in
  both versioned user guides.[1][2]
- The relevant declarations in the locally installed macOS 15.1 and 26.5 SDKs
  are present with the same Core Graphics event-tap and Fn-flag contracts.
- The APIs are architecture-neutral and long predate both releases.

That establishes source and availability continuity, not behavioral proof.
Release support remains gated on the test matrix below. Intel uses the same
public APIs, but should remain outside the initial support promise unless the
extra hardware matrix is accepted; there is no implementation reason to fork
the code.

## Required proving tests

Before calling the mechanism implementation-ready, run a signed,
Hardened-Runtime build on macOS 15 and 26 with:

1. an Apple-silicon laptop built-in keyboard;
2. a wired or Bluetooth Apple Magic Keyboard with Globe;
3. at least one external keyboard with a firmware-only Fn key;
4. Input Monitoring denied, granted, revoked, and re-granted;
5. **Do Nothing**, **Change Input Source**, Emoji, and Dictation settings;
6. tap, hold past 100 ms, Fn plus every top-row function, Fn plus Delete,
   rapid repeats, and overlapping modifiers;
7. Secure Input entered before a gesture and between observed edges;
8. sleep/wake, lock/unlock, fast user switching, keyboard hot-plug, tap timeout,
   and process crash/kill;
9. two keyboards used concurrently;
10. callback-to-switch latency distributions under CPU load.

An active-filter branch may separately test whether swallowing the exact
Globe/Fn event prevents only the standalone action while preserving every
hold/chord. It must also prove permission behavior and synthetic replay. Until
those tests pass on every supported OS/keyboard class, active interception is
not a product fallback.

## Evidence quality and unresolved facts

Documented:

- generic Core Graphics taps can listen or filter, and an active callback can
  delete an event;
- Fn has a public Quartz modifier flag;
- AppKit global monitors are asynchronous and observation-only;
- HID seizure blocks the whole device;
- Secure Input blocks keyboard intercept processes;
- macOS 15 and 26 expose a user-facing Fn/Globe **Do Nothing** setting;
- direct notarization and Mac App Store sandboxing are separate requirements.

Header-derived:

- `kVK_Function = 0x3f`;
- the public `IOHIDEventSystemClient` surface has no event-filter registration;
- virtual HID creation requires
  `com.apple.developer.hid.virtual.device`;
- the relevant macOS 15.1 and 26.5 declarations are unchanged.

Still empirical:

- the exact Quartz sequence emitted by each Globe/Fn keyboard;
- whether the key code is consistently `0x3f` in addition to the Fn flag;
- the precise TCC panel/prompt behavior for the signed listen-only tap;
- whether **Do Nothing** preserves every hardware-specific Fn chord;
- event-tap latency under load;
- active-tap ordering relative to the system's standalone Globe action.

Context7 was queried first as required. It resolved the high-reputation official
collection `/websites/developer_apple_technologyoverviews`, but the fetched
result contained unrelated macOS technology-overview material and no
Globe/Fn, Core Graphics, AppKit, or IOKit guidance. It was therefore not used
as evidence; the conclusions above use primary Apple documentation, headers,
support guides, technical notes, and sample-code records.

## Sources

1. Apple, [Keyboard settings on Mac, macOS 26](https://support.apple.com/guide/mac-help/change-keyboard-settings-on-mac-kbdm162/26/mac/26).
2. Apple, [Keyboard settings on Mac, macOS 15](https://support.apple.com/guide/mac-help/change-keyboard-settings-on-mac-kbdm162/15.0/mac/15.0).
3. Apple Developer Documentation, [`CGEventFlags.maskSecondaryFn`](https://developer.apple.com/documentation/coregraphics/cgeventflags/masksecondaryfn).
4. Apple Developer Documentation, [`CGEvent.tapCreate`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)).
5. Apple Developer Documentation, [`CGEventTapCallBack`](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback); macOS SDK `CoreGraphics.framework/Headers/CGEventTypes.h` and `CGEvent.h`.
6. Apple Developer Documentation, [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox).
7. Apple Developer Documentation, [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
8. macOS SDK, `Carbon.framework/Frameworks/HIToolbox.framework/Headers/Events.h`; `CoreGraphics.framework/Headers/CGEventTypes.h`.
9. Apple Developer Documentation, [`NSEvent.addGlobalMonitorForEvents`](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)).
10. Apple Developer Documentation, [`NSEvent.addLocalMonitorForEvents`](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)).
11. macOS SDK, `IOKit.framework/Headers/hid/IOHIDManager.h`, `IOHIDDevice.h`, and `IOHIDKeys.h`.
12. Apple Technical Note TN2450, [Remapping Keys in macOS 10.12 Sierra](https://developer.apple.com/library/archive/technotes/tn2450/_index.html).
13. macOS SDK, `IOKit.framework/Headers/hidsystem/IOHIDUserDevice.h`.
14. Apple Sample Code Archive, [HID Explorer](https://developer.apple.com/library/archive/samplecode/HID_Explorer/Introduction/Intro.html).
15. Apple Sample Code Archive, [HID Calibrator](https://developer.apple.com/library/archive/samplecode/HID_Calibrator/Introduction/Intro.html).
16. Apple Developer Documentation, [`CGPreflightListenEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()) and [`CGRequestListenEventAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess()).
17. Apple, [Control access to input monitoring on Mac](https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/26/mac/26).
18. Apple, [Allow accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/26/mac/26).
19. Apple Developer Documentation, [`CGPreflightPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()) and macOS SDK `ApplicationServices.framework/Frameworks/HIServices.framework/Headers/AXUIElement.h`.
20. macOS SDK, `Carbon.framework/Frameworks/HIToolbox.framework/Headers/CarbonEventsCore.h`, `EnableSecureEventInput`, `DisableSecureEventInput`, and `IsSecureEventInputEnabled`.
21. Apple Technical Note TN2150, [Using Secure Event Input Fairly](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) (archived; corroborated by the current SDK header).
22. Apple, [Magic Keyboard](https://support.apple.com/guide/imac/magic-keyboard-apd0e7983e19/mac).

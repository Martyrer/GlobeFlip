# Public macOS input-source management

> Historical research from July 2026. SPEC.md is authoritative; supported macOS versions and distribution changed later.

Research date: 2026-07-31

## Conclusion

The current public API is Text Input Source Services (TIS) in
`Carbon.framework/HIToolbox`. It can:

- return a snapshot of enabled keyboard input sources;
- identify the one selected keyboard input source;
- expose documented unique reverse-DNS source IDs and localized display names;
- notify about changes to the selected source and enabled-source set; and
- select an enabled, select-capable source directly.

These capabilities are declared in the current public TIS header.
[H:287-339, 381-398, 725-799, 952-985, 1080-1104]

The public contract does **not** define the order of
`TISCreateInputSourceList` results, expose the order shown by System Settings or
the Input menu, guarantee notification latency/delivery for every intermediate
change, or promise that macOS will never draw system feedback after direct
selection.

The smallest viable implementation is therefore a main-thread TIS adapter that
persists an app-owned order of `kTISPropertyInputSourceID` values, intersects
that order with a fresh enabled/select-capable snapshot, observes both TIS
distributed notifications as invalidation signals, and calls
`TISSelectInputSource` for the next source.

## Primary sources and citation notation

The detailed API documentation is embedded in Apple's current public SDK
header. References below use these abbreviations:

- **H**:
  `/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Headers/TextInputSources.h`
- **N**:
  `/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CoreFoundation.framework/Headers/CFNotificationCenter.h`
- **A**:
  `/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSTextInputContext.h`
- **S**:
  `/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CoreServices.framework/Frameworks/CarbonCore.framework/Headers/Script.h`
- **U**:
  [Write in another language on Mac](https://support.apple.com/guide/mac-help/write-in-another-language-on-mac-mchlp1406/mac)

Resolve the active SDK path with `xcrun --show-sdk-path`; the versioned paths
above make this audit reproducible. Apple's former online Text Input Source
Services route returned HTTP 404 on the research date, so the installed public
SDK headers are the decisive developer reference. No third-party API or private
framework is used.

## Research method

1. Context7 returned no relevant TIS material; SDK headers were used.
2. Located the active public SDK with `xcrun --show-sdk-path`, inspected the TIS,
   Core Foundation notification, AppKit text-context, and CarbonCore migration
   headers, and compiled an Objective-C import check against `Carbon.framework`.
3. Compared SHA-256 hashes of `TextInputSources.h`: the installed 13.1, 14.5,
   15.1, 26.5, and 27.0 SDK copies are identical. The 26.5 and 27.0 copies both
   hash to `e3c1a70e0cb8e21476a8f88f1e247a897a0c7d5723d43e3d63ff091d05927cd9`.
4. Ran a read-only Swift probe on macOS 27.0 to verify discovery and current-ID
   matching. It did not activate another source. The current Apple user guide
   was checked only for documented system switching UI.

## Public API surface

| Need | Public API / property | Documented contract |
| --- | --- | --- |
| Enabled keyboard sources | `TISCreateInputSourceList` with `includeAllInstalled == false`, filtered by `kTISPropertyInputSourceCategory == kTISCategoryKeyboardInputSource` | The result is a snapshot; `false` includes only enabled sources. [H:725-778] |
| Sources that can in principle be selected | `kTISPropertyInputSourceIsSelectCapable` | Static capability, not a promise that current conditions permit selection. [H:248-285] |
| Current source | `TISCopyCurrentKeyboardInputSource()` | Returns the currently selected keyboard input source. [H:787-799] |
| Persistent identity | `kTISPropertyInputSourceID` | A unique reverse-DNS name; layouts, methods, and modes have distinct ID forms. [H:313-339] |
| Display label | `kTISPropertyLocalizedName` | Localized UI name, with possible unlocalized fallback. [H:381-398] |
| Active-source changes | `kTISNotifySelectedKeyboardInputSourceChanged` | Name of a CF distributed notification. [H:1080-1091] |
| Enabled-list changes | `kTISNotifyEnabledKeyboardInputSourcesChanged` | Name of a CF distributed notification for changes to the enabled keyboard-source set. [H:1093-1104] |
| Direct activation | `TISSelectInputSource` | Makes a selectable keyboard source current and deselects the previous one. [H:952-985] |

`TISGetInputSourceProperty` can return `NULL` when a property is missing or
invalid for a source, and its result follows Core Foundation's Get rule.
Property reads must therefore be optional and must not release the returned
object. [H:690-721]

## Discovery and source identity

For the switcher's cycle, request enabled keyboard sources:

```swift
import Carbon

let filter: [CFString: Any] = [
    kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
    kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue as Any,
]

let sources = TISCreateInputSourceList(filter as CFDictionary, false)
    .takeRetainedValue() as! [TISInputSource]
```

`includeAllInstalled == false` is the important boundary: Apple documents it
as including only enabled sources. Passing `true` additionally includes
installed but disabled sources and can force substantially more caching.
[H:730-752, 761-778]

The select-capable filter removes parent input methods and other sources that
can never be selected programmatically. It is not sufficient to prove that
selection will succeed now: an input mode may be enabled and statically
select-capable while its parent method is disabled, in which case the mode is
not currently selectable. [H:233-239, 248-285]

Use `kTISPropertyInputSourceID` as the persisted key. A
`TISInputSourceRef` is unambiguous only within one process and cannot be shared
cross-process, while `kTISPropertyBundleID` is explicitly unavailable for some
keyboard layouts. [H:115-124, 313-356]

Do not use the localized name as identity. Apple defines it as a UI string
selected from the source's available localizations, with fallback behavior.
[H:381-398]

## Current source: source versus layout

Use `TISCopyCurrentKeyboardInputSource()` to identify the active item in the
cycle, then read its `kTISPropertyInputSourceID`. Apple states that exactly one
keyboard input source is selected at a time. [H:91-93, 787-799]

Do **not** use `TISCopyCurrentKeyboardLayoutInputSource()` for active-source
identity. If an input method or input mode is active, that function returns the
keyboard layout used by the method/mode, not the selected method/mode itself.
[H:803-819]

`kTISPropertyInputSourceIsSelected` is also public, but copying the current
source is the direct convenience API and avoids scanning a snapshot.
[H:300-311, 787-799]

## Global selection versus app text contexts

`TISSelectInputSource` is the global selection path. Apple's migration note for
the deprecated Script Manager API explicitly says to use
`TISSelectInputSource` to set the keyboard layout globally. [S:1171-1185]

`NSTextInputContext` is a different, receiver-scoped API owned by an
`NSTextInputClient`. It exposes available and selected source IDs for that text
context, not a documented replacement for the global TIS catalog used by a
menu bar utility. [A:20-35, 82-104] The utility should therefore use TIS and
allow focused apps or documents to change the global source later; the selected
source notification will invalidate its cached state.

## Keyboard layouts, input methods, and IMEs

The keyboard category intentionally includes keyboard layouts, input methods
with and without modes, and input modes. Exactly one member of this category is
selected. [H:512-530]

The relevant public types are:

- `kTISTypeKeyboardLayout`;
- `kTISTypeKeyboardInputMethodWithoutModes`;
- `kTISTypeKeyboardInputMethodModeEnabled`; and
- `kTISTypeKeyboardInputMode`. [H:570-632]

A mode-enabled input method is a non-selectable parent; its modes are directly
selectable. An input method without modes is directly selectable. [H:40-52,
248-278]

Consequently, the cycle should contain enabled sources that are statically
select-capable, regardless of whether they are layouts or IME modes. It should
not special-case the type to layouts only, and it should not include a
mode-enabled parent merely because that parent is enabled.

## Ordering semantics

### Documented guarantee

Apple documents `TISCreateInputSourceList` as returning a snapshot of matching
sources and describes its filtering and installed/enabled boundary. Its full
result contract says only that it returns a `CFArrayRef` of matching
`TISInputSourceRef` objects; no ordering rule, order key, or order parameter is
declared. [H:725-778]

No public property among the filterable TIS keys represents System Settings or
Input menu position. The declared filterable keys cover category, type,
capabilities, enabled/selected state, source ID, bundle ID, input-mode ID, and
localized name. [H:144-157, 160-398]

Therefore, treating array order as the user's system-defined order is an
empirical assumption, not an Apple guarantee.

The receiver-scoped `NSTextInputContext.keyboardInputSources` array also has no
documented ordering contract. [A:82-92] No inspected public API exposes the
System Settings or Input menu order.

### Recommended stable order

Persist an app-owned array of `kTISPropertyInputSourceID` strings:

1. On first discovery, persist the IDs in the returned snapshot order.
2. On refresh, keep persisted IDs in their existing order, skip IDs not in the
   current eligible snapshot, and append newly discovered IDs.
3. Keep unavailable IDs in persisted storage so a temporarily disabled or
   removed source can return to its old position.
4. Offer explicit reordering only if product requirements demand a user-visible
   order editor.

This produces stability after first discovery without relying on undocumented
preferences or private frameworks. It does **not** claim parity with the order
of Apple's Input menu.

## Notifications and refresh

Register both TIS notification names with
`CFNotificationCenterGetDistributedCenter()` and
`CFNotificationCenterAddObserver(...)`. They are distributed, not local,
notifications. [H:1080-1104; N:23-41, 63-66]

Treat callbacks as invalidation signals:

- selected-source change: copy the current source again;
- enabled-source change: rebuild the eligible snapshot and reconcile the
  persisted order.

The TIS declarations specify notification names, but no source object,
`userInfo` schema, ordering, latency, or exactly-once delivery contract.
[H:1074-1104] The Core Foundation API also defines suspension behaviors that
may drop, coalesce, hold, or immediately deliver notifications while an app is
suspended/backgrounded. [N:25-34]

In a UI app, TIS calls must run on the main thread. Distributed notification
delivery also depends on the main thread's run loop running in a common mode.
Neither header specifies delivery latency, ordering, or every intermediate
event. [N:58-63; H:103-106]

## Direct activation and UI behavior

Call:

```swift
let status = TISSelectInputSource(nextSource)
```

For a keyboard source, Apple documents that this makes the source globally
current and deselects the previous source. The target must be enabled and
select-capable; a mode's parent must also be enabled. The result is `paramErr`
when the source is not selectable and `noErr` otherwise. [H:952-985;
S:1171-1185]

`TISSelectInputSource` is the documented direct-selection API and does not
require opening a chooser or synthesizing Apple's "next input source" shortcut.
Apple's user guide documents that holding the system shortcut or Globe/Fn path
can display all sources; that is a reason not to emulate those paths. [U]

The TIS headers do not, however, guarantee that macOS will never draw a HUD,
chooser, or other feedback after direct selection. "No chooser/HUD" remains a
prototype acceptance test on each supported macOS release, not an API promise.

Do not call `TISEnableInputSource` as part of ordinary cycling. Enabling changes
the user's available-source set and is documented mainly for input methods or
apps that supply their own sources. [H:1015-1043]

## Unavailable and changing sources

`TISCreateInputSourceList` is a point-in-time snapshot. Successive snapshots
can differ when sources are enabled or disabled, and Apple posts
`kTISNotifyEnabledKeyboardInputSourcesChanged` for such changes.
[H:725-752, 917-943]

Before selection, use the latest eligible snapshot. If
`TISSelectInputSource` returns an error:

1. refresh once;
2. resolve by source ID against the refreshed snapshot rather than assuming an
   old snapshot still represents current catalog membership;
3. choose the next remaining eligible source; and
4. stop after one bounded retry.

This is defensive policy, not a documented atomicity guarantee. Apple does not
provide a transaction combining list lookup and selection.

If the current source ID is absent from the effective app order, choose the
first eligible source rather than deriving an index from stale state.

When fewer than two eligible sources remain, perform no switch. The system
guarantees at least one enabled keyboard source, but that source is not
necessarily programmatically selectable under every condition. [H:64-75,
248-285]

## Rapid switching and threading

Text Input Source Services is explicitly **not thread-safe**. A UI app must
call it on the main thread. A non-UI process must not call it concurrently from
multiple threads. [H:103-106]

Use one serialized main-thread entry point for:

1. reading a fresh current source;
2. resolving its index in the current effective order;
3. selecting the next source; and
4. checking the returned `OSStatus`.

Do not advance a cached current index merely because a key event arrived, and
do not wait for the distributed selected-source notification before accepting
the next intent. The notification is an invalidation signal, while
`TISCopyCurrentKeyboardInputSource` is the documented source of current
identity. [H:787-799, 1080-1091]

Apple documents neither a rate limit nor completion/notification timing for
rapid repeated `TISSelectInputSource` calls. Preserving every rapid key intent,
the visibility of intermediate sources, and behavior with IME composition are
therefore empirical prototype questions. Main-thread serialization is
required; whether to queue, debounce, or coalesce repeated taps is product
behavior that must be settled by the latency prototype.

## Deployment availability

All required declarations and constants in the inspected public header are
marked `AVAILABLE_MAC_OS_X_VERSION_10_5_AND_LATER`, including discovery,
properties, current-source lookup, selection, and both notifications.
[H:176-196, 246-311, 339-398, 776-799, 985, 1091-1104]

The declarations have no deprecation annotation in the macOS 27.0 public SDK.
The installed macOS 13.1, 14.5, 15.1, 26.5, and 27.0 SDK copies of
`TextInputSources.h` are byte-identical. This is current SDK evidence, not a
promise of future API evolution.

For the planned current-and-previous-major support boundary, the installed
macOS 26.5 and 27.0 SDKs therefore expose the same public, non-deprecated TIS
contract. Runtime behavior was probed only on macOS 27.0; HUD, rapid-switch,
IME, and distribution behavior still need the release-matrix prototype.

The API is macOS-specific and provided by `Carbon.framework`; the public
declarations say CarbonLib and non-Carbon CFM are unavailable. [H:770-778,
979-985]

The app may choose a much newer deployment target for unrelated framework,
Swift, signing, or product reasons. TIS itself does not force that target above
macOS 10.5.

## Smallest viable implementation

Build one small `InputSourceManager`, isolated to the main actor:

```text
refresh()
  snapshot enabled keyboard sources
  keep sources with static select capability
  index sources by InputSourceID
  reconcile persisted ID order

switchNext()
  assert main thread
  read current InputSourceID
  select next source from effective order
  on failure: refresh and retry once

startObserving()
  selected changed -> refresh current identity/UI
  enabled changed  -> refresh snapshot/order
```

Store only source IDs and order. Keep live `TISInputSourceRef` values inside
the process and current snapshot. Use localized names only for display.

No private `TextInput*` framework, preference-file parsing, keyboard-shortcut
simulation, chooser invocation, source-enabling behavior, or separate IME code
path is required.

## Empirical observations and unresolved questions

### Observed locally, not guaranteed

- On macOS 27.0 with the public 27.0 SDK, a public-API probe returned two
  enabled, select-capable layouts. Exactly one had
  `kTISPropertyInputSourceIsSelected == true`, and its ID matched
  `TISCopyCurrentKeyboardInputSource`.
- The probe's array order was deterministic within that run, but no attempt was
  made to infer a system preference from it.
- No activation test was run because it would modify the user's active input
  source.

### Still requiring a focused prototype

- Whether direct TIS selection ever produces a visible source HUD on each
  supported macOS release.
- Exact latency and intermediate-state visibility under very rapid repeated
  selection, especially for IME modes with active composition.
- Behavior when a third-party input method disappears between snapshot and
  selection.
- Whether the product needs parity with Apple's menu order; no public TIS
  contract exposes that order.
- App Sandbox and distribution-channel validation. The TIS declarations expose
  no authorization API, but the inspected headers do not constitute an App
  Review or distribution guarantee.

The target is signed and notarized distribution outside the Mac App Store, so
App Review is not a launch dependency; sandbox and hardened-runtime behavior
still require an actual signed-build check. Apple's public SDK declarations,
rather than an example's incidental behavior, remain the normative source.

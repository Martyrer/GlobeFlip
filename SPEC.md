# GlobeFlip Product and Technical Specification

Status: version 1.0  
Platform: macOS 26 and 27 on Apple Silicon  
Product: `GlobeFlip`  
Bundle identifier: `com.martyrer.GlobeFlip`

## 1. Product Contract

GlobeFlip is a native macOS Menu Bar Utility that interprets a standalone
Globe/Fn tap as a request to advance to the next enabled Input Source. It
switches directly through public Text Input Source Services instead of invoking
Apple's keyboard shortcut or chooser.

GlobeFlip must:

- switch after key-up with the minimum reliable latency;
- discover Input Sources without language-specific code;
- preserve native Fn holds and chords unchanged;
- remain fail-open when permission, event continuity, or source state is
  uncertain;
- expose only focused settings for this behavior;
- run without a Dock icon, daemon, privileged helper, driver, or virtual
  keyboard.

### Terminology

- **Input Source**: a keyboard layout or input method enabled by the user.
- **Active Input Source**: the Input Source currently selected by macOS.
- **Switching Cycle**: the ordered set of currently eligible Input Sources.
- **Globe Tap**: a clean Globe/Fn down and up before the hold threshold, with
  no other input joining the gesture.
- **Fn Hold**: a Globe/Fn press that reaches the threshold or participates in a
  chord and therefore preserves native Fn behavior.

Use these terms in code, UI, logs, and documentation. Do not model the product
as an English/Russian pair or call Input Sources "languages."

## 2. Version 1 Scope

### Included

- Globe/Fn as the only observed control.
- Automatic discovery of enabled, selectable keyboard Input Sources.
- User-controlled cycle order.
- A configurable 50-300 ms tap threshold, defaulting to 150 ms.
- A five-press no-switch calibration tester.
- System, Light, and Dark appearances.
- Optional best-effort trackpad haptic feedback.
- Launch at Login after explicit confirmation.
- Actionable, silent, deduplicated failure notifications.
- Diagnostics and bounded recovery.
- GitHub Releases and an owned Homebrew tap distributing the same ad-hoc-signed,
  not notarized, versioned artifact.

### Excluded

- Other key mappings or general keyboard customization.
- Event suppression, mutation, or synthesized replay.
- An app-owned success HUD or expanded Input Source chooser.
- Accounts, cloud synchronization, analytics, or telemetry.
- App-owned networking, update checks, or a self-updater.
- Mac App Store and Intel support.
- Per-keyboard settings or device attribution.

## 3. Supported Environment

Version 1 is arm64-only and supports the current and previous stable macOS
major releases, initially macOS 27 and 26. A prerelease macOS result must be
replaced by the final stable build before shipping.

Supported keyboard classes are:

- built-in Apple Silicon MacBook keyboards with Globe/Fn;
- Apple Magic Keyboards with Globe over their supported wired and Bluetooth
  paths;
- third-party keyboards only when their Globe/Fn control emits the validated
  public Quartz sequence.

Firmware-only Fn keys that emit no usable Quartz transition are unsupported.
Core Graphics does not provide a public per-device identity for ordinary
keyboard events, so simultaneous keyboards share aggregate state.

The user must set **Press Fn/Globe key to: Do Nothing** in macOS Keyboard
settings. GlobeFlip cannot read this setting through a public API; the user
confirms it, and the confirmation is stored as `systemGlobeActionConfirmed`.
GlobeFlip never changes it.

## 4. User Experience

### First Run

First Run displays one step at a time. Required system and runtime steps gate
Continue; optional choices do not. Switching remains paused until completion:

1. Ask the user to set and confirm **Press Fn/Globe key to: Do Nothing**.
2. Explain and request Input Monitoring after explicit user action.
3. Discover Input Sources and require at least two eligible sources.
4. Require the five-press calibration and apply its recommendation.
5. Offer optional Launch at Login without blocking Continue.
6. Offer optional failure notifications without blocking Continue. A previous
   denial deep-links directly to GlobeFlip's notification switch.
7. Show completion and close only after **Start Using GlobeFlip**.

GlobeFlip must not request Accessibility or event-posting access.

### Menu Bar

The menu bar uses a native pull-down menu with standard macOS hover
highlighting. It is narrow and command-oriented:

- current runtime status;
- Pause Switching or Resume Switching;
- a recovery command while attention is required;
- Settings;
- Quit GlobeFlip.

The application uses `LSUIElement = true` and has no persistent Dock icon.

### Settings

The settings window uses a compact top icon toolbar with:

1. **General**: runtime state, Launch at Login, appearance.
2. **Input Sources**: discovered sources, cycle order, unavailable-source
   recovery.
3. **Timing**: threshold and press tester.
4. **Feedback**: optional haptic behavior.
5. **Statistics**: switch counts, activity, and estimated time saved.
6. **Diagnostics**: permission, event-tap health, latest switch confirmation,
   source health, conflict state, and recovery actions.

The complete visual and accessibility contract is in
`design/01-visual-system.md`.

### Success Feedback

The compact blue indicator that macOS displays beside the caret is accepted
feedback. GlobeFlip does not draw a success HUD, show a success notification,
or wait for visual feedback.

## 5. Gesture Behavior

### Event Source

Create a listen-only Core Graphics session event tap:

- tap: `kCGSessionEventTap`;
- placement: `kCGHeadInsertEventTap`;
- option: `kCGEventTapOptionListenOnly`;
- events: `flagsChanged`, `keyDown`, `keyUp`, and system-defined events needed
  to detect consumer/top-row chords.

The callback always returns the original event. It never suppresses, mutates,
replaces, or posts an event.

Use the public secondary Fn flag transition as the semantic signal. On
validated hardware, key code 63 (`kVK_Function`) is the Globe/Fn discriminator.
An unsupported sequence must fail open instead of being guessed.

### State Machine

The classifier has exactly three states:

```text
Idle
TapCandidate(startTimestamp, thresholdSnapshot)
FnPassThrough(reason)
```

Transitions:

| Current | Input | Next | Switch intent |
| --- | --- | --- | --- |
| Idle | Clean Globe/Fn down, no other input held | TapCandidate | No |
| Idle | Globe/Fn first appears on a non-modifier event or another input is held | FnPassThrough | No |
| TapCandidate | Globe/Fn up before threshold | Idle | Exactly one |
| TapCandidate | Threshold expires | FnPassThrough | No |
| TapCandidate | Any other key, modifier, repeat, consumer, or system event joins | FnPassThrough | No |
| TapCandidate | Event continuity becomes uncertain | Idle | No |
| FnPassThrough | Globe/Fn up | Idle | No |

The threshold comparison is strict: key-up below the snapshotted threshold is
a tap; key-up at or above it is a hold.

The classifier tracks other key-down state and relevant modifier state. A key
already held when Globe/Fn goes down prevents `TapCandidate`. Any second input
joining an active candidate cancels switching even if that input is released
before Globe/Fn.

Focus changes alone do not cancel a candidate. The keyboard event that causes a
focus change does.

### Cancellation

Clear the active gesture without switching or haptic feedback on:

- missing or duplicate Globe/Fn edges;
- event-tap disablement;
- Input Monitoring loss;
- sleep, lock, inactive user session, or process shutdown;
- keyboard topology change;
- any event sequence that cannot be classified unambiguously.

Secure Input is not a state or cancellation condition. Complete Globe/Fn
sequences are classified normally while Secure Input is enabled. GlobeFlip
never calls `DisableSecureEventInput()` and never interferes with its owner.
Ordinary continuity rules still cancel an incomplete sequence.

### Rapid Taps

Every valid Globe Tap creates one immutable `SwitchIntent` containing:

- a monotonically increasing sequence number;
- the Globe key-up timestamp;
- the threshold value used for classification.

Intents enter one FIFO queue. They are never debounced or coalesced. Only one
selection may await confirmation at a time.

## 6. Input Source Model

### Discovery

All TIS work runs on the main thread. Build the eligible snapshot with
`TISCreateInputSourceList`, using:

- `includeAllInstalled = false`;
- category `kTISCategoryKeyboardInputSource`;
- `kTISPropertyInputSourceIsSelectCapable = true`.

For each source retain:

```text
InputSourceDescriptor
  id: String
  localizedName: String
  liveReference: TISInputSource
```

The Input Source ID is persistent identity. The localized name is display-only,
and a live `TISInputSource` reference never leaves the current process snapshot.

### Cycle Order

Persist an ordered array of Input Source IDs:

1. First discovery uses snapshot order.
2. Refresh retains known IDs in their persisted order.
3. IDs not currently eligible remain persisted but are absent from the
   effective cycle.
4. Newly discovered IDs append to the persisted order.
5. User reordering updates the persisted order.

Version 1 cycles all eligible sources and supports reordering, not arbitrary
key mappings. The effective cycle is persisted order intersected with the
latest enabled, selectable snapshot.

If the Active Input Source is outside the effective cycle, the next target is
the first source. With fewer than two eligible sources, no selection or haptic
occurs and GlobeFlip exposes one deduplicated actionable warning.

### Selection Algorithm

For each queued intent:

```text
1. Assert main thread and no selection already in flight.
2. Read the latest Active Input Source with
   TISCopyCurrentKeyboardInputSource().
3. Resolve the next target from the current effective cycle.
4. Call TISSelectInputSource(target).
5. If status == noErr:
     confirm the target asynchronously.
6. If status != noErr:
     refresh once;
     retry the same target ID once only if it is still eligible;
     otherwise fail the intent.
7. Never select a different target for the same Globe Tap.
```

An `OSStatus` of `noErr` means that the request was accepted, not synchronously
confirmed.

### Confirmation

After an accepted request:

1. Reread the Active Input Source immediately.
2. If it does not match, reread every 2 ms without blocking the main thread.
3. Stop on a match or at a 100 ms deadline.
4. A selected-source notification may trigger an earlier reread.

On confirmation:

- record key-up-to-confirmation latency;
- clear the matching warning condition;
- publish the Active Input Source and health snapshot;
- remove the intent from the queue;
- schedule optional haptic feedback;
- process the next intent without awaiting UI or haptic work.

On timeout, rejection, or target disappearance:

- end the current intent without haptic;
- refresh discovery at most once;
- never choose a replacement target for that intent;
- expose one deduplicated warning;
- accept a later tap only after the relevant source state is healthy.

If a confirmed target is immediately displaced without another GlobeFlip
intent, treat it as an unstable source or competing remapper. Stop retries,
pause switching, and offer Check Again.

### TIS Notifications

Observe both distributed notifications:

- `kTISNotifySelectedKeyboardInputSourceChanged`;
- `kTISNotifyEnabledKeyboardInputSourcesChanged`.

They are invalidation signals only. They may be delayed, duplicated, coalesced,
or out of order. They never create a switch intent and are never treated as an
exactly-once completion event.

## 7. Runtime Architecture

Use one user-session Swift application process with the SwiftUI lifecycle.
There is no daemon, XPC service, login helper, watchdog, or privileged
component.

| Component | Responsibility | Execution context |
| --- | --- | --- |
| `GlobeEventMonitor` | Permission-aware listen-only event tap and health | Dedicated thread and `CFRunLoop` |
| `GlobeGestureClassifier` | Pure three-state gesture logic | Event-tap thread |
| `SwitchCoordinator` | FIFO intents and one in-flight selection | Main actor |
| `InputSourceManager` | TIS discovery, order reconciliation, selection, confirmation | Main actor |
| `RuntimeCoordinator` | Pause, lifecycle, permission, bounded recovery, haptic requests after confirmation, and published UI state | Main actor |
| `PreferencesStore` | Validated app-owned `UserDefaults` | Main actor |
| `FailureNotificationService` (private, in `GlobeFlip/RuntimeCoordinator.swift`) | Silent deduplicated failure notifications | Asynchronous |

The event-tap callback performs timestamp and classifier updates only. It does
no TIS, UI, disk, network, Service Management, notification, or haptic work.

Use native SwiftUI, AppKit, Core Graphics, IOKit, Carbon/HIToolbox, Service
Management, and User Notifications. Do not add a UI framework,
state-management framework, dependency-injection container, database, or
third-party control library.

## 8. Permissions and Lifecycle

### Input Monitoring

- Call `CGPreflightListenEventAccess()` before creating the event tap.
- Call `CGRequestListenEventAccess()` only from the onboarding action.
- While denied, create no active event pipeline and emit no switch intent.
- Check Again re-evaluates permission and starts the pipeline when allowed.
- On runtime revocation, stop accepting intents within one second, clear state,
  remain fail-open, and expose one warning.

Do not repeatedly trigger the system prompt. Relaunch is acceptable only if a
tested macOS release requires it and the UI says so explicitly.

### Launch at Login

Use `SMAppService.mainApp`:

- call `register()` only after explicit confirmation;
- call `unregister()` when disabled;
- display the queried system status, not a cached Boolean;
- use `openSystemSettingsLoginItems()` when approval is required.

Registration failure never blocks manual operation.

### Session and Device Lifecycle

After sleep/wake, lock/unlock, fast user switching, or keyboard topology
changes:

1. stop accepting new intents;
2. clear gesture, queued intents, and in-flight confirmation;
3. rebuild the event tap;
4. refresh Input Sources;
5. publish Ready only after both services are healthy.

If macOS disables the event tap, re-enable or recreate it once. A second
failure within 30 seconds pauses switching and requires explicit recovery.

## 9. Preferences

Store only app-owned settings in `UserDefaults`:

| Setting | Type | Default | Validation |
| --- | --- | --- | --- |
| `sourceOrder` | `[String]` | First eligible snapshot | Reconcile by Input Source ID |
| `tapThresholdMilliseconds` | `Int` | `150` | Clamp to `50...300`, 10 ms UI steps |
| `appearance` | enum | `system` | `system`, `light`, or `dark` |
| `hapticEnabled` | `Bool` | `false` | Boolean |
| `hapticPulseCount` | `Int` | `1` | Clamp to `1...3` |
| `switchingPaused` | `Bool` | `false` | Boolean |
| `onboardingCompleted` | `Bool` | `false` | Boolean |
| `systemGlobeActionConfirmed` | `Bool` | `false` | Boolean |
| switch statistics | daily counts | empty | Local successful switches only |

Do not persist Active Input Source, permission, event-tap health, notification
authorization, Secure Input, or Launch at Login as authoritative state. Query
their system APIs.

Reset to Defaults requires confirmation, clears only app-owned preferences,
and does not revoke permissions or alter Login Item registration.

## 10. Timing Calibration

The threshold control is a native slider from 50 to 300 ms in 10 ms steps. The
current value and 150 ms recommended baseline remain visible.

The press tester:

1. suspends switching for its own captured samples;
2. records five standalone Globe/Fn press durations;
3. displays a live 50-300 ms horizontal duration meter while Globe/Fn is held;
4. uses a green-to-red semantic scale, moving marker, and numeric value so
   duration is never communicated by color alone;
5. displays all five samples;
6. calculates `ceilTo10ms(max(samples) + 25 ms)`;
7. clamps the result to 50-300 ms;
8. changes the setting only after Apply.

Reset discards tester samples. Closing the tester restores the prior runtime
state and never changes the Active Input Source.

## 11. Feedback and Failure States

### Haptics

When enabled, request the configured pulse count from
`NSHapticFeedbackManager.defaultPerformer` after a confirmed switch. Settings
changes preview feedback. Never await delivery in the switching path.

No haptic is requested for a hold, chord, rejected tap, timeout, cancellation,
conflict, recovery action, or unsupported hardware.

### Warnings

| Condition | Runtime action | Recovery |
| --- | --- | --- |
| Input Monitoring missing or revoked | Pause and remove event pipeline | Open System Settings, Check Again |
| Fewer than two eligible sources | Do not consume intents | Open Input Sources, Check Again |
| Target rejected, missing, or unconfirmed | End intent, refresh once, no alternate target | Check Again after source repair |
| Immediate target displacement | Pause; no repeated selection | Disable competing remapper, Check Again |
| Repeated event-tap failure | Pause after bounded recreation | Check Again or relaunch |
| Launch at Login approval/failure | Continue manual operation | Open Login Items |

Each unresolved condition produces at most one silent system notification.
Notification denial never blocks switching or recovery. The menu bar and
Diagnostics always expose the same action.

## 12. Appearance and Accessibility

Appearance offers System, Light, and Dark; System is the default. Changes apply
without relaunching to the settings window, menus, and sheets.

Use native controls, SF Symbols, semantic colors, system text styles, keyboard
navigation, and VoiceOver labels. Respect Increase Contrast and Reduce Motion.
No decorative transition may enter the event-to-confirmation path.

Settings use the compact visual grammar defined in
`design/01-visual-system.md`, without copying branding or using decorative
cards, gradients, or custom window chrome.

## 13. Security and Privacy

- Use only public user-space APIs.
- Enable Hardened Runtime for Release builds.
- Do not enable App Sandbox for direct distribution.
- Use IOKit HID only to notice keyboards connecting or disconnecting; read no
  HID input values.
- Use no root, setuid, DriverKit, virtual-device, private-API, or helper
  entitlement.
- Observe events only; never store or log typed keys or text.
- Write no logs. Diagnostics shown in Settings contain only timestamps, event
  categories, state transitions, source IDs, status codes, and latency.
- Make no app-owned network request.
- Collect no analytics or telemetry.

## 14. Distribution and Updates

Ship one ad-hoc-signed, not notarized, versioned artifact through GitHub
Releases. The owned Homebrew tap exposes Cask token `globeflip` and installs that same immutable
artifact by URL and SHA-256. Documentation must explain macOS Gatekeeper's
first-launch warning. Developer ID signing and notarization remain an optional
future upgrade.

Version 1 has no updater framework or background update check. Website users
update manually; Homebrew users update through Homebrew.

Sparkle 2 is a possible later addition outside the event and switching
architecture. Mac App Store distribution requires a separate sandboxed
feasibility prototype and is not a version 1 build target.

## 15. Performance Contract

Measure switching from the observed Globe key-up timestamp to confirmed target
activation:

- normal-load p95: at most 20 ms;
- sustained-CPU-load p95: at most 30 ms;
- every success: at most the 100 ms confirmation deadline;
- control run: zero rejection, timeout, wrong target, duplicate, or out-of-order
  completion.

Report p50, p95, p99, and maximum for every release configuration. UI,
notifications, caret feedback, and haptics are outside this measurement and
must not block it.

With no input and the menu closed:

- no repeating polling timer or network request;
- average CPU at most 0.5% over ten minutes on the reference Mac;
- no sustained wakeup loop;
- no resident-memory growth above 10 MiB over an eight-hour idle run without an
  accepted explanation.

The event-tap callback p99 must remain below 1 ms.

## 16. Verification and Release Gates

Release requires:

- automated state-machine, queue, cycle, retry, confirmation, preference,
  warning, and lifecycle tests;
- UI tests for onboarding, settings, calibration, recovery, appearance, and
  accessibility (planned);
- a 1,000-gesture primary soak with zero classifier or native Fn failures;
- at least 100 mixed gestures on every additional OS/keyboard matrix entry;
- fixed-attempt Secure Input tests with 20 taps before, during, and after;
- permission deny, grant, revoke, and regrant on both supported macOS releases;
- lifecycle, hot-plug, IME, composition, notification, conflict, and
  application-compatibility checks;
- exact Release artifact checksum, expected Gatekeeper behavior, Homebrew
  install/upgrade, resource, and no-network checks.

Missing hardware or an unrun required scenario fails the support claim. It is
not an assumed pass.

## 17. Proven Baseline

Current macOS 27 prototype evidence establishes:

- public key-code-63 Fn transitions through a listen-only session event tap;
- clean tap, hold, and chord classification without event mutation;
- 25/25 normal, rapid, and limited-load TIS switches;
- key-up-to-confirmation latency of 1.246-17.430 ms;
- bounded asynchronous confirmation after `TISSelectInputSource(noErr)`;
- duplicate and delayed TIS notifications as invalidation-only signals;
- 10/10 Globe pairs before, 10/10 during, and 10/10 after Secure Input;
- direct TIS confirmation under Secure Input in 10.268 ms;
- 3/3 combined Globe-to-TIS switches under Secure Input in
  8.589-17.411 ms;
- the accepted compact macOS caret indicator;
- conflict when another Globe remapper handles the same physical tap.

This evidence proves the architecture on the current machine. It does not
replace the signed release matrix for macOS 26, external keyboards, IMEs,
permissions, lifecycle recovery, or final Developer ID distribution.
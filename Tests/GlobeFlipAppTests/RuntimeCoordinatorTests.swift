import AppKit
import Carbon
import Combine
import Foundation
import Testing

@testable import GlobeFlip
@testable import GlobeFlipCore

@Suite("Keyboard topology debounce")
struct KeyboardTopologyDebounceTests {
  @Test("Maximum wait bounds a continuous event stream")
  func boundedKeyboardTopologyDebounce() {
    var debounce = KeyboardTopologyDebounce()

    #expect(
      debounce.delay(at: 0)
        == KeyboardTopologyDebounce.delayNanoseconds
    )
    #expect(debounce.delay(at: 300_000_000) == 400_000_000)
    #expect(debounce.delay(at: 1_200_000_000) == 300_000_000)
    #expect(debounce.delay(at: 1_499_000_000) == 1_000_000)
    #expect(debounce.delay(at: 1_500_000_000) == nil)
    #expect(
      debounce.delay(at: 2_000_000_000)
        == KeyboardTopologyDebounce.delayNanoseconds
    )
  }
}

@Suite("Runtime coordinator")
@MainActor
struct RuntimeCoordinatorTests {
  @Test("Hosted test process is detected so the host runtime stays off")
  func hostedTestProcessIsDetected() {
    #expect(
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
        != nil
    )
  }

  @Test("Inactive runtime ignores wake and session notifications")
  func inactiveRuntimeIgnoresLifecycleNotifications() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    let center = NSWorkspace.shared.notificationCenter

    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    center.post(
      name: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil
    )
    await drainMainQueue()
    await drainMainQueue()

    #expect(harness.monitor.startCount == 0)
    #expect(harness.monitor.state == .idle)
  }

  @Test("System Settings destinations address requested panes")
  func systemSettingsDestinations() {
    #expect(
      SystemSettingsDestination.inputMonitoring.url?.absoluteString
        == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
    )
    #expect(
      SystemSettingsDestination.keyboard.url?.absoluteString
        == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    )
    #expect(
      SystemSettingsDestination.notifications(
        bundleIdentifier: "com.martyrer.GlobeFlip"
      ).url?.absoluteString
        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.martyrer.GlobeFlip"
    )
  }

  @Test("Settings controls preview haptics when enabled")
  func settingsControlsPreviewHaptics() {
    let harness = RuntimeHarness(onboarded: false)
    defer { harness.cleanUp() }
    harness.preferences.hapticEnabled = true
    let runtime: RuntimeCoordinator = harness.runtime

    runtime.setTapThresholdMilliseconds(160)
    runtime.setSwitchingPaused(true)
    runtime.setSystemGlobeActionConfirmed(true)
    #expect(harness.hapticCount == 3)

    runtime.setSwitchingPaused(true)
    #expect(harness.hapticCount == 3)

    runtime.setHapticEnabled(false)
    #expect(harness.hapticCount == 4)
    runtime.setTapThresholdMilliseconds(170)
    #expect(harness.hapticCount == 4)
  }

  @Test("Unchanged statistics are not published")
  func unchangedStatisticsAreNotPublished() {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    var publicationCount = 0
    let cancellable = harness.runtime.$statistics
      .dropFirst()
      .sink { _ in publicationCount += 1 }

    harness.runtime.refreshStatistics()
    harness.runtime.refreshStatistics()

    #expect(publicationCount == 0)
    withExtendedLifetime(cancellable) {}
  }

  @Test("Recorded switch publishes statistics once")
  func recordedSwitchPublishesOnce() {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    var publicationCount = 0
    let cancellable = harness.runtime.$statistics
      .dropFirst()
      .sink { _ in publicationCount += 1 }

    harness.statisticsStore.recordSuccessfulSwitch(latencyMilliseconds: 20)
    harness.runtime.refreshStatistics()
    harness.runtime.refreshStatistics()

    #expect(publicationCount == 1)
    #expect(harness.runtime.statistics.todayCount == 1)
    withExtendedLifetime(cancellable) {}
  }

  @Test("Tap switches once when every runtime gate is open")
  func tapSwitchesWhenReady() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    await harness.startRunning()

    await harness.tap()

    #expect(harness.selections == ["b"])
    #expect(harness.activeID == "b")
    #expect(harness.runtime.inputSourceSnapshot.activeSourceID == "b")
    #expect(harness.runtime.lastSwitchResult?.failure == nil)
    #expect(harness.runtime.lastSwitchResult?.latencyMilliseconds != nil)
    #expect(harness.warnings == [])
  }

  @Test("A tap that arrives before the event tap runs is ignored")
  func tapBeforeRunningIsIgnored() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    harness.runtime.checkAgain()
    #expect(harness.monitor.state == .starting)
    #expect(harness.runtime.eventMonitorHealth == .starting)

    await harness.tap()

    #expect(harness.selections == [])
  }

  @Test("Closed runtime gate drops taps until it reopens", arguments: ClosedGate.allCases)
  func closedGateDropsTaps(gate: ClosedGate) async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    await harness.startRunning()

    await harness.close(gate)
    let selectionsBefore = harness.selections.count
    await harness.tap()
    #expect(harness.selections.count == selectionsBefore)
    #expect(harness.warnings == gate.expectedWarnings)

    await harness.open(gate)
    #expect(harness.warnings == [])
    #expect(harness.runtime.eventMonitorHealth == .running)
    await harness.tap()
    #expect(harness.selections.count == selectionsBefore + 1)
    #expect(harness.runtime.lastSwitchResult?.failure == nil)
  }

  @Test("Interruption cancels an in-flight intent without reporting it", arguments: Interruption.allCases)
  func interruptionCancelsInFlightIntent(interruption: Interruption) async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    harness.preferences.hapticEnabled = true
    await harness.startRunning()
    harness.selection = .leavePending

    harness.monitor.emitTap(keyUpTimestamp: harness.now)
    await drainMainQueue()
    await drainMainQueue()
    #expect(harness.selections == ["b"])
    #expect(harness.runtime.switches.queueDepth == 1)

    let hapticsBefore = harness.hapticCount
    await harness.interrupt(interruption)
    #expect(harness.runtime.switches.queueDepth == 0)
    await drainMainQueue()
    await drainMainQueue()

    #expect(harness.runtime.lastSwitchResult == nil)
    #expect(harness.selections == ["b"])
    #expect(harness.recordedSwitchCount == 0)
    #expect(harness.hapticCount - hapticsBefore == interruption.previewHaptics)
  }

  @Test("Rejected selection is reported as the latest switch result")
  func rejectedSelectionIsReported() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    await harness.startRunning()
    await harness.tap()
    #expect(harness.runtime.lastSwitchResult?.failure == nil)

    harness.selection = .rejectAlways
    await harness.tap()

    #expect(harness.selections == ["b", "a", "a"])
    #expect(
      harness.runtime.lastSwitchResult == .failed(.selectionRejected(-1))
    )
    #expect(harness.warnings == [.sourceSelection])
  }

  @Test("Haptics and statistics follow confirmed switches only")
  func hapticsAndStatisticsFollowConfirmedSwitches() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    harness.preferences.hapticEnabled = true
    await harness.startRunning()

    await harness.tap()
    #expect(harness.hapticCount == 1)
    #expect(harness.recordedSwitchCount == 1)

    harness.selection = .neverConfirm
    await harness.tap()
    #expect(
      harness.runtime.lastSwitchResult == .failed(.confirmationTimedOut)
    )

    harness.selection = .rejectAlways
    await harness.tap()
    #expect(harness.selections == ["b", "a", "a", "a"])
    #expect(harness.hapticCount == 1)
    #expect(harness.recordedSwitchCount == 1)
  }

  @Test("Check Again restarts a stopped pipeline exactly once")
  func checkAgainRestartsOnce() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    await harness.startRunning()
    #expect(harness.monitor.startCount == 1)

    harness.runtime.checkAgain()
    #expect(harness.monitor.stopCount == 1)
    #expect(harness.monitor.startCount == 1)
    harness.monitor.finishStop()
    await drainMainQueue()
    #expect(harness.monitor.startCount == 2)
    #expect(harness.runtime.eventMonitorHealth == .starting)
    harness.monitor.finishStart(.running)
    await drainMainQueue()
    #expect(harness.runtime.eventMonitorHealth == .running)

    // A later stop that no recovery requested is not restarted.
    harness.monitor.stop()
    harness.monitor.finishStop()
    await drainMainQueue()
    #expect(harness.monitor.startCount == 2)
    #expect(harness.runtime.eventMonitorHealth == .stopped)
    #expect(harness.runtime.canCheckAgain)
  }

  @Test("Repeated event-tap failure waits for explicit recovery")
  func eventTapFailureRequiresExplicitRecovery() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    await harness.startRunning()

    harness.monitor.fail(.repeatedEventTapDisablement)
    await drainMainQueue()

    #expect(
      harness.runtime.eventMonitorHealth
        == .failed(.repeatedEventTapDisablement)
    )
    #expect(harness.monitor.startCount == 1)
    #expect(harness.warnings == [.eventTap])
    #expect(harness.runtime.canCheckAgain)

    harness.runtime.restartEventTap()
    #expect(harness.monitor.startCount == 2)
  }

  @Test("Lifecycle suspension stops the pipeline until resume")
  func lifecycleSuspensionStopsUntilResume() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    await harness.startRunning()

    harness.runtime.suspendForLifecycle()
    #expect(harness.monitor.stopCount == 1)
    harness.monitor.finishStop()
    await drainMainQueue()
    #expect(harness.runtime.eventMonitorHealth == .stopped)
    #expect(harness.monitor.startCount == 1)

    harness.runtime.resumeAfterLifecycle()
    #expect(harness.monitor.startCount == 2)
    await harness.settleMonitor()
    await harness.tap()
    #expect(harness.selections == ["b"])
  }

  @Test("Permission denial exposes the Input Monitoring warning")
  func permissionDenial() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    harness.runtime.checkAgain()
    harness.monitor.finishStart(.permissionRequired)
    await drainMainQueue()

    #expect(harness.runtime.eventMonitorHealth == .permissionRequired)
    #expect(harness.warnings == [.inputMonitoring])
    #expect(harness.runtime.canCheckAgain)
    #expect(harness.monitor.startCount == 1)

    harness.runtime.checkAgain()
    harness.monitor.finishStart(.running)
    await drainMainQueue()
    #expect(harness.monitor.startCount == 2)
    #expect(harness.warnings == [])
    #expect(!harness.runtime.canCheckAgain)
  }

  @Test("Threshold changes reach the event monitor clamped")
  func thresholdReachesMonitor() {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    #expect(harness.monitor.thresholdMilliseconds == 150)

    harness.runtime.setTapThresholdMilliseconds(200)
    #expect(harness.monitor.thresholdMilliseconds == 200)

    harness.preferences.tapThresholdMilliseconds = 400
    #expect(harness.monitor.thresholdMilliseconds == 300)
  }

  @Test("Calibration collects five presses then stops the tester")
  func calibrationCollectsFivePresses() async {
    let harness = RuntimeHarness()
    defer { harness.cleanUp() }
    harness.runtime.startCalibration()
    #expect(!harness.runtime.calibrationActive)

    await harness.startRunning()
    harness.runtime.startCalibration()
    #expect(harness.runtime.calibrationActive)
    #expect(harness.monitor.calibrationEnabled)

    harness.monitor.emitCalibration(.pressBegan(timestamp: 7))
    await drainMainQueue()
    #expect(harness.runtime.calibrationPressStartedAt == 7)
    harness.monitor.emitCalibration(.cancelled)
    await drainMainQueue()
    #expect(harness.runtime.calibrationPressStartedAt == nil)

    for duration in [80.0, 95, 101, 90, 70, 60] {
      harness.monitor.emitCalibration(
        .pressEnded(durationMilliseconds: duration)
      )
    }
    await drainMainQueue()

    #expect(harness.runtime.calibrationSamples == [80, 95, 101, 90, 70])
    #expect(!harness.monitor.calibrationEnabled)
    #expect(harness.runtime.calibrationSuggestedThreshold == 130)

    harness.runtime.applyCalibration()
    #expect(harness.preferences.tapThresholdMilliseconds == 130)
    #expect(harness.monitor.thresholdMilliseconds == 130)
  }
}

@Suite("Failure notification service")
@MainActor
struct FailureNotificationServiceTests {
  @Test("Unresolved warning notifies once across repeated updates")
  func notifiesOnce() async {
    let recorder = NotificationRecorder()
    let service = recorder.makeService()

    for _ in 0..<3 {
      service.update(unresolved: [.eventTap], enabled: true)
      await drainMainQueue()
    }

    #expect(recorder.delivered == [.eventTap])
    #expect(recorder.withdrawn == [])
  }

  @Test("Resolved warning is withdrawn and notifies again when it recurs")
  func recurringWarningNotifiesAgain() async {
    let recorder = NotificationRecorder()
    let service = recorder.makeService()

    service.update(unresolved: [.eventTap, .launchAtLogin], enabled: true)
    await drainMainQueue()
    service.update(unresolved: [.launchAtLogin], enabled: true)
    await drainMainQueue()
    #expect(recorder.withdrawn == [[FailureWarning.eventTap.notificationIdentifier]])

    service.update(unresolved: [.eventTap, .launchAtLogin], enabled: true)
    await drainMainQueue()

    #expect(
      recorder.delivered.sorted(by: { $0.rawValue < $1.rawValue })
        == [.eventTap, .eventTap, .launchAtLogin]
    )
  }

  @Test("Disabled notifications defer delivery until enabled")
  func disabledNotificationsDefer() async {
    let recorder = NotificationRecorder()
    let service = recorder.makeService()

    service.update(unresolved: [.inputMonitoring], enabled: false)
    await drainMainQueue()
    #expect(recorder.delivered == [])

    service.update(unresolved: [.inputMonitoring], enabled: true)
    await drainMainQueue()
    service.update(unresolved: [.inputMonitoring], enabled: true)
    await drainMainQueue()
    #expect(recorder.delivered == [.inputMonitoring])
  }

  @Test("Failed delivery retries on the next update")
  func failedDeliveryRetries() async {
    let recorder = NotificationRecorder()
    recorder.failuresRemaining = 1
    let service = recorder.makeService()

    service.update(unresolved: [.sourceConflict], enabled: true)
    await drainMainQueue()
    #expect(recorder.attempts == 1)
    #expect(recorder.delivered == [])

    service.update(unresolved: [.sourceConflict], enabled: true)
    await drainMainQueue()
    #expect(recorder.attempts == 2)
    #expect(recorder.delivered == [.sourceConflict])
  }

  @Test("Warning resolved before delivery runs is never delivered")
  func resolvedBeforeDeliveryIsSkipped() async {
    let recorder = NotificationRecorder()
    let service = recorder.makeService()

    service.update(unresolved: [.insufficientSources], enabled: true)
    service.update(unresolved: [], enabled: true)
    await drainMainQueue()

    #expect(recorder.attempts == 0)
    #expect(
      recorder.withdrawn
        == [[FailureWarning.insufficientSources.notificationIdentifier]]
    )
  }

  @Test("Warning identifiers are namespaced by bundle")
  func warningIdentifiers() {
    #expect(
      FailureWarning.sourceSelection.notificationIdentifier
        == "\(Bundle.main.bundleIdentifier ?? "GlobeFlip").warning.sourceSelection"
    )
  }
}

@MainActor
private final class NotificationRecorder {
  var delivered: [FailureWarning] = []
  var withdrawn: [[String]] = []
  var attempts = 0
  var failuresRemaining = 0

  func makeService() -> FailureNotificationService {
    FailureNotificationService(
      deliver: { [self] warning in
        attempts += 1
        if failuresRemaining > 0 {
          failuresRemaining -= 1
          throw CancellationError()
        }
        delivered.append(warning)
      },
      withdraw: { [self] identifiers in
        withdrawn.append(identifiers)
      }
    )
  }
}

enum ClosedGate: CaseIterable, Sendable, CustomTestStringConvertible {
  case paused
  case calibrating
  case globeActionUnconfirmed
  case onboardingIncomplete
  case lifecycleSuspended
  case recoveryPending
  case insufficientSources
  case sourceConflict
  case permissionRequired
  case eventTapFailed

  var testDescription: String { "\(self)" }

  var expectedWarnings: Set<FailureWarning> {
    switch self {
    case .globeActionUnconfirmed: [.systemGlobeAction]
    case .insufficientSources: [.insufficientSources]
    case .sourceConflict: [.sourceConflict]
    case .permissionRequired: [.inputMonitoring]
    case .eventTapFailed: [.eventTap]
    case .paused, .calibrating, .onboardingIncomplete, .lifecycleSuspended,
      .recoveryPending:
      []
    }
  }
}

enum Interruption: CaseIterable, Sendable, CustomTestStringConvertible {
  case pause
  case sourceRemoved
  case eventTapFailed
  case lifecycleSuspended
  case calibrationStarted
  case globeActionUnconfirmed
  case checkAgain

  var testDescription: String { "\(self)" }

  /// Settings changes preview haptics; nothing else may play one.
  var previewHaptics: Int {
    switch self {
    case .pause, .globeActionUnconfirmed: 1
    default: 0
    }
  }
}

/// Stands in for the event tap. It follows the real monitor's start/stop
/// rules and only reports health when a test completes a pending step.
final class FakeGlobeEventMonitor: GlobeEventMonitoring, @unchecked Sendable {
  enum State: Equatable {
    case idle
    case starting
    case running
  }

  private(set) var state = State.idle
  private(set) var stopRequested = false
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var thresholdMilliseconds: Int?
  private(set) var calibrationEnabled = false
  private var onTap: (@Sendable (GlobeTap) -> Void)?
  private var onCalibrationEvent:
    (@Sendable (GlobeEventMonitor.CalibrationEvent) -> Void)?
  private var onHealthChange: (@Sendable (GlobeEventMonitor.Health) -> Void)?

  func updateThreshold(_ milliseconds: Int) {
    thresholdMilliseconds = milliseconds
  }

  func setCalibrationEnabled(_ enabled: Bool) {
    calibrationEnabled = enabled
  }

  func start(
    onTap: @escaping @Sendable (GlobeTap) -> Void,
    onGlobeInput: @escaping @Sendable (GlobeEventMonitor.GlobeInputEdge) -> Void,
    onCalibrationEvent:
      @escaping @Sendable (GlobeEventMonitor.CalibrationEvent) -> Void,
    onHealthChange: @escaping @Sendable (GlobeEventMonitor.Health) -> Void,
    onKeyboardTopologyChange: @escaping @Sendable () -> Void
  ) {
    guard state == .idle else { return }
    self.onTap = onTap
    self.onCalibrationEvent = onCalibrationEvent
    self.onHealthChange = onHealthChange
    state = .starting
    stopRequested = false
    startCount += 1
  }

  func stop() {
    stopCount += 1
    stopRequested = true
  }

  /// Completes a pending start the way the event-tap thread would.
  func finishStart(_ health: GlobeEventMonitor.Health) {
    guard state == .starting else { return }
    if health == .running, stopRequested {
      state = .idle
      stopRequested = false
      onHealthChange?(.stopped)
    } else {
      state = health == .running ? .running : .idle
      onHealthChange?(health)
    }
  }

  /// Completes a requested stop of a running event loop.
  func finishStop() {
    guard state == .running, stopRequested else { return }
    state = .idle
    stopRequested = false
    onHealthChange?(.stopped)
  }

  func fail(_ failure: GlobeEventMonitor.Failure) {
    guard state == .running else { return }
    state = .idle
    stopRequested = false
    onHealthChange?(.failed(failure))
  }

  /// A single tap disablement that re-enabled successfully.
  func reenable() {
    guard state == .running else { return }
    onHealthChange?(.running)
  }

  func emitTap(keyUpTimestamp: UInt64) {
    onTap?(
      GlobeTap(
        keyUpTimestamp: keyUpTimestamp,
        thresholdMilliseconds: thresholdMilliseconds ?? 150
      )
    )
  }

  func emitCalibration(_ event: GlobeEventMonitor.CalibrationEvent) {
    onCalibrationEvent?(event)
  }
}

/// A runtime wired to a fake event tap and fake Input Source services.
@MainActor
final class RuntimeHarness {
  enum Selection: CaseIterable {
    case confirm
    case rejectOnce
    case rejectAlways
    /// Accepts the request, then lets the confirmation window pass.
    case neverConfirm
    /// Accepts the request and holds the clock, so the intent stays in
    /// flight until something cancels it.
    case leavePending
    case removeTargetAndReject
  }

  let suiteName: String
  let defaults: UserDefaults
  let preferences: PreferencesStore
  let statisticsStore: SwitchStatisticsStore
  let monitor = FakeGlobeEventMonitor()
  var sources: [InputSourceItem]
  var activeID: String?
  /// The Input Source manager's clock. It only moves when a selection
  /// lets the confirmation window pass.
  private(set) var now: UInt64 = 1_000_000_000
  var selection = Selection.confirm {
    didSet { rejectedOnce = false }
  }
  /// Called before every selection request, for invariant checks.
  var onSelect: ((String) -> Void)?
  private(set) var selections: [String] = []
  private(set) var activations = 0
  private(set) var hapticCount = 0
  private(set) var inputSources: InputSourceManager!
  private(set) var runtime: RuntimeCoordinator!
  private var rejectedOnce = false

  init(sourceIDs: [String] = ["a", "b"], onboarded: Bool = true) {
    suiteName = "RuntimeHarness.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    preferences = PreferencesStore(defaults: defaults)
    preferences.onboardingCompleted = onboarded
    preferences.systemGlobeActionConfirmed = onboarded
    statisticsStore = SwitchStatisticsStore(defaults: defaults)
    sources = sourceIDs.map { InputSourceItem(id: $0, localizedName: $0) }
    activeID = sourceIDs.first
    inputSources = InputSourceManager(
      preferences: preferences,
      discoverSources: { [weak self] in self?.sources ?? [] },
      currentSourceID: { [weak self] in self?.activeID },
      selectSource: { [weak self] id in
        self?.select(id) ?? OSStatus(paramErr)
      },
      now: { [weak self] in self?.now ?? 0 }
    )
    runtime = RuntimeCoordinator(
      preferences: preferences,
      statisticsStore: statisticsStore,
      activatesRuntime: false,
      monitor: monitor,
      inputSources: inputSources,
      hapticPerformer: { [weak self] in self?.hapticCount += 1 }
    )
  }

  var recordedSwitchCount: Int {
    runtime.refreshStatistics()
    return runtime.statistics.totalCount
  }

  /// Warnings that do not depend on the host's Login Item registration.
  var warnings: Set<FailureWarning> {
    runtime.activeWarnings.subtracting([.launchAtLogin])
  }

  func cleanUp() {
    runtime.switches.cancelAll()
    defaults.removePersistentDomain(forName: suiteName)
  }

  func startRunning() async {
    runtime.checkAgain()
    await settleMonitor()
  }

  /// Completes pending stop and start steps until the monitor is idle or
  /// running with no stop requested.
  func settleMonitor() async {
    for _ in 0..<4 {
      await drainMainQueue()
      if monitor.state == .running, monitor.stopRequested {
        monitor.finishStop()
      } else if monitor.state == .starting {
        monitor.finishStart(.running)
      } else {
        break
      }
    }
    await drainMainQueue()
  }

  /// Emits a tap and waits for the switch queue to drain.
  func tap() async {
    monitor.emitTap(keyUpTimestamp: now)
    await settleSwitches()
  }

  func settleSwitches() async {
    for _ in 0..<1_000 {
      await drainMainQueue()
      if runtime.switches.queueDepth == 0 {
        await drainMainQueue()
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Switch queue did not drain")
  }

  func notifySourcesChanged() {
    inputSources.receiveNotification(.enabledSourcesChanged)
  }

  func setSources(_ ids: [String]) {
    sources = ids.map { InputSourceItem(id: $0, localizedName: $0) }
    notifySourcesChanged()
  }

  func close(_ gate: ClosedGate) async {
    switch gate {
    case .paused:
      runtime.setSwitchingPaused(true)
    case .calibrating:
      runtime.startCalibration()
    case .globeActionUnconfirmed:
      runtime.setSystemGlobeActionConfirmed(false)
    case .onboardingIncomplete:
      preferences.onboardingCompleted = false
    case .lifecycleSuspended:
      runtime.suspendForLifecycle()
    case .recoveryPending:
      runtime.checkAgain()
    case .insufficientSources:
      setSources(["a"])
    case .sourceConflict:
      await tap()
      activeID = "a"
      inputSources.receiveNotification(.selectedSourceChanged)
    case .permissionRequired:
      monitor.stop()
      monitor.finishStop()
      await drainMainQueue()
      runtime.checkAgain()
      monitor.finishStart(.permissionRequired)
    case .eventTapFailed:
      monitor.fail(.repeatedEventTapDisablement)
    }
    await drainMainQueue()
  }

  func open(_ gate: ClosedGate) async {
    switch gate {
    case .paused:
      runtime.setSwitchingPaused(false)
    case .calibrating:
      runtime.stopCalibration()
    case .globeActionUnconfirmed:
      runtime.setSystemGlobeActionConfirmed(true)
    case .onboardingIncomplete:
      preferences.onboardingCompleted = true
    case .lifecycleSuspended:
      runtime.resumeAfterLifecycle()
    case .recoveryPending:
      break
    case .insufficientSources:
      setSources(["a", "b"])
    case .sourceConflict, .permissionRequired, .eventTapFailed:
      runtime.checkAgain()
    }
    await settleMonitor()
  }

  func interrupt(_ interruption: Interruption) async {
    switch interruption {
    case .pause:
      runtime.setSwitchingPaused(true)
    case .sourceRemoved:
      setSources(["a"])
    case .eventTapFailed:
      monitor.fail(.eventTapCouldNotBeReenabled)
      await drainMainQueue()
    case .lifecycleSuspended:
      runtime.suspendForLifecycle()
    case .calibrationStarted:
      runtime.startCalibration()
    case .globeActionUnconfirmed:
      runtime.setSystemGlobeActionConfirmed(false)
    case .checkAgain:
      runtime.checkAgain()
    }
  }

  private func select(_ id: String) -> OSStatus {
    onSelect?(id)
    selections.append(id)
    switch selection {
    case .confirm:
      return activate(id)
    case .rejectOnce:
      guard rejectedOnce else {
        rejectedOnce = true
        return OSStatus(-1)
      }
      rejectedOnce = false
      return activate(id)
    case .rejectAlways:
      return OSStatus(-1)
    case .neverConfirm:
      now += SwitchIntent.confirmationWindowNanoseconds
      return noErr
    case .leavePending:
      return noErr
    case .removeTargetAndReject:
      sources.removeAll { $0.id == id }
      return OSStatus(-1)
    }
  }

  private func activate(_ id: String) -> OSStatus {
    activeID = id
    activations += 1
    return noErr
  }
}

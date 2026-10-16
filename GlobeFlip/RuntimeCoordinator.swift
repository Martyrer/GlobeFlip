import AppKit
import Combine
import Foundation
import GlobeFlipCore
import ServiceManagement
import SwiftUI
import UserNotifications

enum LaunchAtLoginStatus: Equatable, Sendable {
  case disabled
  case enabled
  case requiresApproval
  case unavailable
  case failed

  var title: String {
    switch self {
    case .disabled:
      "Disabled"
    case .enabled:
      "Enabled"
    case .requiresApproval:
      "Approval Required"
    case .unavailable:
      "Unavailable"
    case .failed:
      "Registration Failed"
    }
  }
}

enum NotificationAuthorizationState: Equatable, Sendable {
  case notDetermined
  case denied
  case authorized

  var title: String {
    switch self {
    case .notDetermined:
      "Not Requested"
    case .denied:
      "Denied"
    case .authorized:
      "Enabled"
    }
  }
}

enum SystemSettingsDestination: Equatable {
  case inputMonitoring
  case keyboard
  case notifications(bundleIdentifier: String)

  var url: URL? {
    let value =
      switch self {
      case .inputMonitoring:
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
      case .keyboard:
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
      case .notifications(let bundleIdentifier):
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)"
      }
    return URL(string: value)
  }
}

struct KeyboardTopologyDebounce {
  static let delayNanoseconds: UInt64 = 400_000_000
  static let maximumWaitNanoseconds: UInt64 = 1_500_000_000

  private var firstEventTimestamp: UInt64?

  mutating func delay(at timestamp: UInt64) -> UInt64? {
    guard let firstEventTimestamp else {
      self.firstEventTimestamp = timestamp
      return Self.delayNanoseconds
    }
    let elapsed =
      timestamp >= firstEventTimestamp
      ? timestamp - firstEventTimestamp
      : 0
    guard elapsed < Self.maximumWaitNanoseconds else {
      reset()
      return nil
    }
    return min(
      Self.delayNanoseconds,
      Self.maximumWaitNanoseconds - elapsed
    )
  }

  mutating func reset() {
    firstEventTimestamp = nil
  }
}

enum FailureWarning: String, Hashable, Sendable {
  case inputMonitoring
  case insufficientSources
  case sourceSelection
  case sourceConflict
  case eventTap
  case launchAtLogin
  case systemGlobeAction
  case systemSettings

  var notificationTitle: String {
    switch self {
    case .inputMonitoring:
      "GlobeFlip needs Input Monitoring"
    case .insufficientSources:
      "GlobeFlip needs two Input Sources"
    case .sourceSelection:
      "GlobeFlip could not switch Input Sources"
    case .sourceConflict:
      "Another utility changed the Input Source"
    case .eventTap:
      "GlobeFlip monitoring stopped"
    case .launchAtLogin:
      "GlobeFlip needs Login Item attention"
    case .systemGlobeAction:
      "Confirm the system Globe action"
    case .systemSettings:
      "GlobeFlip could not open System Settings"
    }
  }

  var notificationBody: String {
    switch self {
    case .inputMonitoring:
      "Open Privacy & Security > Input Monitoring. Confirm GlobeFlip is listed and enabled. If it is already enabled, remove it, add the current GlobeFlip.app again, quit and reopen GlobeFlip, then choose Check Again."
    case .insufficientSources:
      "Open Keyboard > Text Input > Edit. Add or enable at least two keyboard layouts, then choose Check Again."
    case .sourceSelection:
      "Open Keyboard > Text Input > Edit. Confirm both layouts are enabled, select each once from the menu bar, then choose Check Again."
    case .sourceConflict:
      "Temporarily quit other keyboard remappers or Input Source switchers, then choose Check Again."
    case .eventTap:
      "Choose Check Again. If monitoring still fails, verify Input Monitoring is enabled for this GlobeFlip.app and relaunch it."
    case .launchAtLogin:
      "Open General > Login Items & Extensions and allow GlobeFlip to run in the background."
    case .systemGlobeAction:
      "Open Keyboard settings, set Press Fn/Globe key to Do Nothing, then confirm the setting in GlobeFlip."
    case .systemSettings:
      "Open System Settings manually and navigate to the requested setting."
    }
  }

  var notificationIdentifier: String {
    "\(Bundle.main.bundleIdentifier ?? "GlobeFlip").warning.\(rawValue)"
  }
}

@MainActor
final class FailureNotificationService {
  private let deliver: @MainActor (FailureWarning) async throws -> Void
  private let withdraw: @MainActor ([String]) -> Void
  private var unresolved: Set<FailureWarning> = []
  private var notified: Set<FailureWarning> = []

  init(
    deliver: @escaping @MainActor (FailureWarning) async throws -> Void =
      FailureNotificationService.deliverSystemNotification,
    withdraw: @escaping @MainActor ([String]) -> Void =
      FailureNotificationService.withdrawSystemNotifications
  ) {
    self.deliver = deliver
    self.withdraw = withdraw
  }

  static func deliverSystemNotification(_ warning: FailureWarning) async throws {
    let content = UNMutableNotificationContent()
    content.title = warning.notificationTitle
    content.body = warning.notificationBody
    try await UNUserNotificationCenter.current().add(
      UNNotificationRequest(
        identifier: warning.notificationIdentifier,
        content: content,
        trigger: nil
      )
    )
  }

  static func withdrawSystemNotifications(_ identifiers: [String]) {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
  }

  func update(
    unresolved newUnresolved: Set<FailureWarning>,
    enabled: Bool
  ) {
    let resolved = unresolved.subtracting(newUnresolved)
    unresolved = newUnresolved
    notified.subtract(resolved)

    let resolvedIDs = resolved.map(\.notificationIdentifier)
    if !resolvedIDs.isEmpty {
      withdraw(resolvedIDs)
    }

    guard enabled else { return }
    let newWarnings = unresolved.subtracting(notified)
    notified.formUnion(newWarnings)

    Task { [weak self] in
      for warning in newWarnings {
        guard let self, self.unresolved.contains(warning) else {
          self?.notified.remove(warning)
          continue
        }

        do {
          try await self.deliver(warning)
          if !self.unresolved.contains(warning) {
            self.notified.remove(warning)
            self.withdraw([warning.notificationIdentifier])
          }
        } catch {
          self.notified.remove(warning)
        }
      }
    }
  }
}

@MainActor
final class RuntimeCoordinator: ObservableObject {
  @Published private(set) var eventMonitorHealth: GlobeEventMonitor.Health = .stopped
  @Published private(set) var lastGlobeInputAt: Date?
  @Published private(set) var lastGlobeDownAt: Date?
  @Published private(set) var lastGlobeUpAt: Date?
  @Published private(set) var lastGlobeDownBlockingInput: String?
  @Published private(set) var inputSourceSnapshot: InputSourceSnapshot
  @Published private(set) var lastSwitchResult: InputSourceSwitchResult?
  @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
  @Published private(set) var notificationAuthorization: NotificationAuthorizationState =
    .notDetermined
  @Published private(set) var inputMonitoringRequestMade = false
  @Published private(set) var activeWarnings: Set<FailureWarning> = []
  @Published private(set) var calibrationActive = false
  @Published private(set) var calibrationPressStartedAt: UInt64?
  @Published private(set) var calibrationSamples: [Double] = []
  @Published private(set) var statistics: SwitchStatisticsSnapshot
  @Published private(set) var systemSettingsOpenFailed = false

  var calibrationSuggestedThreshold: Int? {
    TimingCalibration.recommendedThreshold(samples: calibrationSamples)
  }

  var canCheckAgain: Bool {
    if inputSourceSnapshot.health != .ready {
      return true
    }
    return switch eventMonitorHealth {
    case .stopped, .permissionRequired, .failed:
      true
    case .starting, .running:
      false
    }
  }

  private let preferences: PreferencesStore
  private let monitor: any GlobeEventMonitoring
  private let inputSources: InputSourceManager
  let switches: SwitchCoordinator
  private let statisticsStore: SwitchStatisticsStore
  private let hapticPerformer: @MainActor () -> Void
  private let notificationService = FailureNotificationService()
  private var cancellables: Set<AnyCancellable> = []
  private var systemSettingsReturnCancellable: AnyCancellable?
  private var hapticTask: Task<Void, Never>?
  private var keyboardTopologyRecoveryTask: Task<Void, Never>?
  private var keyboardTopologyDebounce = KeyboardTopologyDebounce()
  private var lifecycleActive = true
  private var recoveryRequested = false

  init(
    preferences: PreferencesStore,
    statisticsStore: SwitchStatisticsStore = SwitchStatisticsStore(),
    activatesRuntime: Bool = true,
    monitor: any GlobeEventMonitoring = GlobeEventMonitor(),
    inputSources: InputSourceManager? = nil,
    hapticPerformer: @escaping @MainActor () -> Void = {
      NSHapticFeedbackManager.defaultPerformer.perform(
        .generic,
        performanceTime: .now
      )
    }
  ) {
    self.preferences = preferences
    self.statisticsStore = statisticsStore
    self.hapticPerformer = hapticPerformer
    self.statistics = statisticsStore.snapshot
    self.monitor = monitor
    let inputSources =
      inputSources ?? InputSourceManager(preferences: preferences)
    self.inputSources = inputSources
    self.switches = SwitchCoordinator(inputSources: inputSources)
    self.inputSourceSnapshot = inputSources.snapshot

    monitor.updateThreshold(preferences.tapThresholdMilliseconds)
    preferences.$tapThresholdMilliseconds
      .removeDuplicates()
      .sink { [monitor] threshold in
        monitor.updateThreshold(threshold)
      }
      .store(in: &cancellables)

    preferences.$appearance
      .removeDuplicates()
      .sink { appearance in
        NSApplication.shared.appearance = appearance.appKitAppearance
      }
      .store(in: &cancellables)

    preferences.$systemGlobeActionConfirmed
      .removeDuplicates()
      .sink { [weak self] confirmed in
        if !confirmed {
          self?.switches.cancelAll()
        }
        // @Published sinks run before the stored value changes.
        self?.updateWarnings(systemGlobeActionConfirmed: confirmed)
      }
      .store(in: &cancellables)

    inputSources.$snapshot
      .sink { [weak self] snapshot in
        self?.inputSourceSnapshot = snapshot
        if snapshot.health != .ready {
          self?.switches.cancelAll(reportingActiveFailure: true)
        }
        self?.updateWarnings()
      }
      .store(in: &cancellables)

    switches.onCompletion = { [weak self] _, result in
      guard let self else { return }
      self.lastSwitchResult = result
      guard result.failure == nil else { return }
      self.statisticsStore.recordSuccessfulSwitch(
        latencyMilliseconds: result.latencyMilliseconds
      )
      if self.preferences.hapticEnabled {
        self.performHapticFeedback()
      }
    }

    preferences.$switchingPaused
      .removeDuplicates()
      .sink { [weak self] paused in
        if paused {
          self?.switches.cancelAll()
        }
      }
      .store(in: &cancellables)

    refreshLaunchAtLogin()
    guard activatesRuntime else { return }
    installLifecycleNotifications()
    refreshNotificationAuthorization()
    startIfPermitted()
  }

  deinit {
    hapticTask?.cancel()
    keyboardTopologyRecoveryTask?.cancel()
    monitor.stop()
  }

  func requestInputMonitoring() {
    inputMonitoringRequestMade = true
    _ = GlobeEventMonitor.requestInputMonitoringPermission()
    startIfPermitted()
  }

  func checkAgain() {
    beginRecovery(clearSourceConflict: true)
  }

  func restartEventTap() {
    beginRecovery(clearSourceConflict: false)
  }

  func moveInputSource(id: String, by offset: Int) {
    inputSources.moveSource(id: id, by: offset)
  }

  func resetPreferences() {
    switches.cancelAll()
    stopCalibration()
    calibrationSamples = []
    preferences.reset()
    inputSources.recover()
  }

  func resetStatistics() {
    statisticsStore.reset()
    statistics = statisticsStore.snapshot
  }

  func setSwitchingPaused(_ paused: Bool) {
    guard preferences.switchingPaused != paused else { return }
    preferences.switchingPaused = paused
    playHapticFeedback()
  }

  func setSystemGlobeActionConfirmed(_ confirmed: Bool) {
    guard preferences.systemGlobeActionConfirmed != confirmed else { return }
    preferences.systemGlobeActionConfirmed = confirmed
    playHapticFeedback()
  }

  func setTapThresholdMilliseconds(_ threshold: Int) {
    guard preferences.tapThresholdMilliseconds != threshold else { return }
    preferences.tapThresholdMilliseconds = threshold
    playHapticFeedback()
  }

  func setHapticEnabled(_ enabled: Bool) {
    guard preferences.hapticEnabled != enabled else { return }
    let shouldPlay = preferences.hapticEnabled || enabled
    preferences.hapticEnabled = enabled
    if shouldPlay {
      performHapticFeedback()
    }
  }

  func setHapticPulseCount(_ count: Int) {
    guard preferences.hapticPulseCount != count else { return }
    preferences.hapticPulseCount = count
    playHapticFeedback()
  }

  func startCalibration() {
    guard eventMonitorHealth == .running else { return }
    switches.cancelAll()
    calibrationSamples = []
    calibrationPressStartedAt = nil
    calibrationActive = true
    monitor.setCalibrationEnabled(true)
  }

  func resetCalibration() {
    calibrationSamples = []
    calibrationPressStartedAt = nil
    monitor.setCalibrationEnabled(calibrationActive)
  }

  func applyCalibration() {
    guard let threshold = calibrationSuggestedThreshold else { return }
    preferences.tapThresholdMilliseconds = threshold
  }

  func stopCalibration() {
    calibrationActive = false
    calibrationPressStartedAt = nil
    monitor.setCalibrationEnabled(false)
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    let service = SMAppService.mainApp

    do {
      if enabled, service.status != .enabled {
        try service.register()
      } else if !enabled, service.status != .notRegistered {
        try service.unregister()
      }
      refreshLaunchAtLogin()
    } catch {
      refreshLaunchAtLogin()
      if launchAtLoginStatus != .requiresApproval {
        launchAtLoginStatus = .failed
      }
    }
  }

  func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  func openSystemSettings() {
    openSystemSettingsApplication(
      .inputMonitoring,
      recheckInputMonitoring: true
    )
  }

  func openKeyboardSettings() {
    openSystemSettingsApplication(.keyboard)
  }

  func openNotificationSettings() {
    openSystemSettingsApplication(
      .notifications(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? ""
      )
    )
  }

  func requestFailureNotifications() {
    Task {
      do {
        _ = try await UNUserNotificationCenter.current()
          .requestAuthorization(options: [.alert])
      } catch {
        notificationAuthorization = .denied
        return
      }
      refreshNotificationAuthorization()
    }
  }

  func refreshSystemState() {
    refreshLaunchAtLogin()
    refreshNotificationAuthorization()
  }

  func refreshStatistics() {
    statisticsStore.refresh()
    guard statistics != statisticsStore.snapshot else { return }
    statistics = statisticsStore.snapshot
  }

  private func receive(_ tap: GlobeTap) {
    guard eventMonitorHealth == .running,
      lifecycleActive,
      !recoveryRequested,
      inputSourceSnapshot.health == .ready,
      !calibrationActive,
      preferences.systemGlobeActionConfirmed,
      preferences.onboardingCompleted,
      !preferences.switchingPaused
    else { return }
    switches.enqueue(tap)
  }

  private func performHapticFeedback() {
    hapticTask?.cancel()
    hapticTask = nil
    hapticPerformer()
    guard preferences.hapticPulseCount > 1 else { return }

    let pulseCount = preferences.hapticPulseCount
    hapticTask = Task { @MainActor in
      for _ in 1..<pulseCount {
        try? await Task.sleep(for: .milliseconds(65))
        guard !Task.isCancelled else { return }
        hapticPerformer()
      }
    }
  }

  private func playHapticFeedback() {
    guard preferences.hapticEnabled else { return }
    performHapticFeedback()
  }

  private func startIfPermitted() {
    guard eventMonitorHealth != .starting, eventMonitorHealth != .running
    else { return }

    eventMonitorHealth = .starting
    lastGlobeInputAt = nil
    lastGlobeDownAt = nil
    lastGlobeUpAt = nil
    lastGlobeDownBlockingInput = nil
    updateWarnings()

    monitor.start(
      onTap: { [weak self] tap in
        DispatchQueue.main.async {
          self?.receive(tap)
        }
      },
      onGlobeInput: { [weak self] edge in
        DispatchQueue.main.async {
          guard let self else { return }
          self.lastGlobeInputAt = .now
          switch edge {
          case .down(let blockingInput):
            self.lastGlobeDownAt = .now
            self.lastGlobeDownBlockingInput = blockingInput
          case .up:
            self.lastGlobeUpAt = .now
          }
        }
      },
      onCalibrationEvent: { [weak self] event in
        DispatchQueue.main.async {
          self?.receiveCalibrationEvent(event)
        }
      },
      onHealthChange: { [weak self] health in
        DispatchQueue.main.async {
          guard let self else { return }
          if health != .running {
            self.switches.cancelAll()
          }
          self.eventMonitorHealth = health
          if health == .running {
            self.recoveryRequested = false
            self.inputMonitoringRequestMade = false
          } else if health == .stopped,
            self.recoveryRequested,
            self.lifecycleActive
          {
            self.inputSources.refresh()
            self.startIfPermitted()
          }
          self.updateWarnings()
        }
      },
      onKeyboardTopologyChange: { [weak self] in
        DispatchQueue.main.async {
          self?.scheduleKeyboardTopologyRecovery()
        }
      }
    )
  }

  private func receiveCalibrationEvent(
    _ event: GlobeEventMonitor.CalibrationEvent
  ) {
    guard calibrationActive else { return }

    switch event {
    case .pressBegan(let timestamp):
      guard calibrationSamples.count < TimingCalibration.requiredSampleCount
      else {
        return
      }
      calibrationPressStartedAt = timestamp

    case .pressEnded(let durationMilliseconds):
      guard calibrationSamples.count < TimingCalibration.requiredSampleCount
      else {
        return
      }
      calibrationPressStartedAt = nil
      calibrationSamples.append(durationMilliseconds)
      if calibrationSamples.count == TimingCalibration.requiredSampleCount {
        monitor.setCalibrationEnabled(false)
      }

    case .cancelled:
      calibrationPressStartedAt = nil
    }
  }

  private func installLifecycleNotifications() {
    let center = NSWorkspace.shared.notificationCenter
    Publishers.Merge(
      center.publisher(for: NSWorkspace.willSleepNotification),
      center.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in
      self?.suspendForLifecycle()
    }
    .store(in: &cancellables)

    Publishers.Merge(
      center.publisher(for: NSWorkspace.didWakeNotification),
      center.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in
      self?.resumeAfterLifecycle()
    }
    .store(in: &cancellables)

    NotificationCenter.default.publisher(
      for: NSApplication.didBecomeActiveNotification
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in
      self?.refreshSystemState()
      self?.refreshStatistics()
    }
    .store(in: &cancellables)

    NotificationCenter.default.publisher(
      for: NSApplication.willTerminateNotification
    )
    .sink { [weak self] _ in
      self?.statisticsStore.flush()
    }
    .store(in: &cancellables)
  }

  func suspendForLifecycle() {
    lifecycleActive = false
    recoveryRequested = false
    keyboardTopologyRecoveryTask?.cancel()
    keyboardTopologyRecoveryTask = nil
    keyboardTopologyDebounce.reset()
    switches.cancelAll()
    statisticsStore.flush()
    monitor.stop()
  }

  func resumeAfterLifecycle() {
    lifecycleActive = true
    beginRecovery(clearSourceConflict: false)
  }

  private func beginRecovery(clearSourceConflict: Bool) {
    recoveryRequested = true
    switches.cancelAll()
    if clearSourceConflict {
      inputSources.recover()
    } else {
      inputSources.refresh()
    }

    switch eventMonitorHealth {
    case .running, .starting:
      monitor.stop()
    case .stopped, .permissionRequired, .failed:
      startIfPermitted()
    }
  }

  private func scheduleKeyboardTopologyRecovery() {
    keyboardTopologyRecoveryTask?.cancel()
    let delay = keyboardTopologyDebounce.delay(
      at: DispatchTime.now().uptimeNanoseconds
    )
    guard let delay else {
      keyboardTopologyRecoveryTask = nil
      beginRecovery(clearSourceConflict: false)
      return
    }
    keyboardTopologyRecoveryTask = Task { [weak self] in
      try? await Task.sleep(for: .nanoseconds(Int64(delay)))
      guard !Task.isCancelled, let self else { return }
      self.keyboardTopologyDebounce.reset()
      self.keyboardTopologyRecoveryTask = nil
      self.beginRecovery(clearSourceConflict: false)
    }
  }

  private func refreshLaunchAtLogin() {
    let status: LaunchAtLoginStatus =
      switch SMAppService.mainApp.status {
      case .notRegistered:
        .disabled
      case .enabled:
        .enabled
      case .requiresApproval:
        .requiresApproval
      case .notFound:
        .unavailable
      @unknown default:
        .unavailable
      }
    if launchAtLoginStatus != status {
      launchAtLoginStatus = status
    }
    updateWarnings()
  }

  private func openSystemSettingsApplication(
    _ destination: SystemSettingsDestination,
    recheckInputMonitoring: Bool = false
  ) {
    watchForSystemSettingsReturn(
      recheckInputMonitoring: recheckInputMonitoring
    )
    NSApplication.shared.activate()
    DispatchQueue.main.async {
      var opened = destination.url.map(NSWorkspace.shared.open) ?? false
      if !opened {
        opened = NSWorkspace.shared.open(
          URL(
            fileURLWithPath: "/System/Applications/System Settings.app"
          )
        )
      }
      self.systemSettingsOpenFailed = !opened
      self.updateWarnings()
    }
  }

  private func watchForSystemSettingsReturn(
    recheckInputMonitoring: Bool
  ) {
    systemSettingsReturnCancellable?.cancel()
    systemSettingsReturnCancellable = NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didDeactivateApplicationNotification)
      .compactMap {
        $0.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
      }
      .filter { $0.bundleIdentifier == "com.apple.systempreferences" }
      .prefix(1)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        self.systemSettingsReturnCancellable = nil
        self.refreshSystemState()
        if recheckInputMonitoring {
          self.beginRecovery(clearSourceConflict: true)
        }
        NSApplication.shared.activate()
      }
  }

  private func refreshNotificationAuthorization() {
    Task {
      let settings = await UNUserNotificationCenter.current()
        .notificationSettings()
      let authorization: NotificationAuthorizationState =
        switch settings.authorizationStatus {
        case .notDetermined:
          .notDetermined
        case .denied:
          .denied
        case .authorized, .provisional:
          .authorized
        case .ephemeral:
          .authorized
        @unknown default:
          .denied
        }
      if notificationAuthorization != authorization {
        notificationAuthorization = authorization
      }
      updateWarnings()
    }
  }

  private func updateWarnings(systemGlobeActionConfirmed: Bool? = nil) {
    var warnings: Set<FailureWarning> = []

    if eventMonitorHealth == .permissionRequired {
      warnings.insert(.inputMonitoring)
    }
    if case .failed = eventMonitorHealth {
      warnings.insert(.eventTap)
    }

    switch inputSourceSnapshot.health {
    case .ready:
      break
    case .insufficientSources:
      warnings.insert(.insufficientSources)
    case .selectionFailed:
      warnings.insert(.sourceSelection)
    case .conflict:
      warnings.insert(.sourceConflict)
    }

    if launchAtLoginStatus == .requiresApproval
      || launchAtLoginStatus == .failed
    {
      warnings.insert(.launchAtLogin)
    }
    if !(systemGlobeActionConfirmed ?? preferences.systemGlobeActionConfirmed) {
      warnings.insert(.systemGlobeAction)
    }
    if systemSettingsOpenFailed {
      warnings.insert(.systemSettings)
    }

    if activeWarnings != warnings {
      activeWarnings = warnings
    }
    notificationService.update(
      unresolved: warnings,
      enabled: notificationAuthorization == .authorized
    )
  }
}

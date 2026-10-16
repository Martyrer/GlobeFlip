import Carbon
import CoreGraphics
import Foundation
import GlobeFlipCore
import IOKit.hid

/// The event-tap surface `RuntimeCoordinator` drives. Tests substitute a fake
/// so runtime behavior never depends on the real tap or Input Monitoring.
protocol GlobeEventMonitoring: AnyObject, Sendable {
  func updateThreshold(_ milliseconds: Int)
  func setCalibrationEnabled(_ enabled: Bool)
  func start(
    onTap: @escaping @Sendable (GlobeTap) -> Void,
    onGlobeInput: @escaping @Sendable (GlobeEventMonitor.GlobeInputEdge) -> Void,
    onCalibrationEvent:
      @escaping @Sendable (GlobeEventMonitor.CalibrationEvent) -> Void,
    onHealthChange: @escaping @Sendable (GlobeEventMonitor.Health) -> Void,
    onKeyboardTopologyChange: @escaping @Sendable () -> Void
  )
  func stop()
}

/// Bounds event-tap recovery: one re-enable per disablement, but a second
/// disablement within the window is terminal until explicit recovery.
struct EventTapDisablementHistory {
  static let repeatedFailureWindowNanoseconds: UInt64 = 30_000_000_000

  private var lastDisablementTimestamp: UInt64?

  mutating func recordIsRepeated(at timestamp: UInt64) -> Bool {
    if let lastDisablementTimestamp,
      timestamp >= lastDisablementTimestamp,
      timestamp - lastDisablementTimestamp
        <= Self.repeatedFailureWindowNanoseconds
    {
      return true
    }
    lastDisablementTimestamp = timestamp
    return false
  }
}

final class GlobeEventMonitor: GlobeEventMonitoring, @unchecked Sendable {
  enum CalibrationEvent: Equatable, Sendable {
    case pressBegan(timestamp: UInt64)
    case pressEnded(durationMilliseconds: Double)
    case cancelled
  }

  enum Failure: Equatable, Sendable {
    case eventTapCreationFailed
    case eventTapCouldNotBeReenabled
    case repeatedEventTapDisablement
  }

  enum Health: Equatable, Sendable {
    case stopped
    case permissionRequired
    case starting
    case running
    case failed(Failure)
  }

  enum GlobeInputEdge: Sendable {
    case down(blockingInput: String?)
    case up
  }

  private struct SharedState {
    var callbacks: Callbacks?
    var eventTap: CFMachPort?
    var runLoop: CFRunLoop?
    var starting = false
    var stopRequested = false
    var terminalHealth: Health?
    var thresholdMilliseconds = TimingCalibration.defaultThresholdMilliseconds
    var calibrationEnabled = false
    var calibrationGeneration: UInt64 = 0
  }

  private struct Callbacks {
    let onTap: @Sendable (GlobeTap) -> Void
    let onGlobeInput: @Sendable (GlobeInputEdge) -> Void
    let onCalibrationEvent: @Sendable (CalibrationEvent) -> Void
    let onHealthChange: @Sendable (Health) -> Void
    let onKeyboardTopologyChange: @Sendable () -> Void
  }

  private static let globeKeyCode = Int64(kVK_Function)
  private static let maximumKeyCode = Int64(kVK_UpArrow)
  private static let systemDefinedEventTypeRawValue: UInt32 = 14
  private static let heldModifierMask: CGEventFlags = [
    .maskShift,
    .maskControl,
    .maskAlternate,
    .maskCommand,
    .maskHelp,
  ]
  private static let eventMask =
    [
      CGEventType.flagsChanged,
      .keyDown,
      .keyUp,
    ].reduce(CGEventMask(0)) { mask, type in
      mask | (CGEventMask(1) << type.rawValue)
    }
    | (CGEventMask(1) << systemDefinedEventTypeRawValue)

  private static let callback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else {
      return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<GlobeEventMonitor>
      .fromOpaque(userInfo)
      .takeUnretainedValue()
    monitor.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
  }
  private static let keyboardMatchedCallback: IOHIDDeviceCallback = {
    context, _, _, device in
    guard let context else { return }
    Unmanaged<GlobeEventMonitor>
      .fromOpaque(context)
      .takeUnretainedValue()
      .receiveKeyboardDevice(device, connected: true)
  }
  private static let keyboardRemovedCallback: IOHIDDeviceCallback = {
    context, _, _, device in
    guard let context else { return }
    Unmanaged<GlobeEventMonitor>
      .fromOpaque(context)
      .takeUnretainedValue()
      .receiveKeyboardDevice(device, connected: false)
  }

  private let stateLock = NSLock()
  private var sharedState = SharedState()

  // Event-thread-only state.
  private var classifier = GlobeGestureClassifier()
  private var fnDown = false
  private var otherKeysDown: Set<Int64> = []
  private var calibrationStartTimestamp: UInt64?
  private var calibrationGeneration: UInt64 = 0
  private var disablementHistory = EventTapDisablementHistory()
  private var hidManager: IOHIDManager?
  private var keyboardDevices: Set<ObjectIdentifier> = []
  private var topologyCallbacksEnabled = false

  static func requestInputMonitoringPermission() -> Bool {
    CGRequestListenEventAccess()
  }

  func updateThreshold(_ milliseconds: Int) {
    withSharedState {
      $0.thresholdMilliseconds = min(
        max(milliseconds, TimingCalibration.allowedRange.lowerBound),
        TimingCalibration.allowedRange.upperBound
      )
    }
  }

  func setCalibrationEnabled(_ enabled: Bool) {
    withSharedState {
      $0.calibrationEnabled = enabled
      $0.calibrationGeneration &+= 1
    }
  }

  func start(
    onTap: @escaping @Sendable (GlobeTap) -> Void,
    onGlobeInput: @escaping @Sendable (GlobeInputEdge) -> Void,
    onCalibrationEvent: @escaping @Sendable (CalibrationEvent) -> Void,
    onHealthChange: @escaping @Sendable (Health) -> Void,
    onKeyboardTopologyChange: @escaping @Sendable () -> Void
  ) {
    let shouldStart = withSharedState { state in
      guard !state.starting, state.runLoop == nil else { return false }
      state.callbacks = Callbacks(
        onTap: onTap,
        onGlobeInput: onGlobeInput,
        onCalibrationEvent: onCalibrationEvent,
        onHealthChange: onHealthChange,
        onKeyboardTopologyChange: onKeyboardTopologyChange
      )
      state.starting = true
      state.stopRequested = false
      state.terminalHealth = nil
      return true
    }
    guard shouldStart else { return }

    let thread = Thread { [weak self] in
      self?.runEventLoop()
    }
    thread.name = "GlobeFlip.event-tap"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  func stop() {
    let runLoop = withSharedState { state in
      state.stopRequested = true
      return state.runLoop
    }
    guard let runLoop else { return }
    CFRunLoopStop(runLoop)
    CFRunLoopWakeUp(runLoop)
  }

  private func runEventLoop() {
    autoreleasepool {
      guard CGPreflightListenEventAccess() else {
        finishStarting(with: .permissionRequired)
        return
      }

      guard
        let eventTap = CGEvent.tapCreate(
          tap: .cgSessionEventTap,
          place: .headInsertEventTap,
          options: .listenOnly,
          eventsOfInterest: Self.eventMask,
          callback: Self.callback,
          userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
      else {
        finishStarting(with: .failed(.eventTapCreationFailed))
        return
      }

      let runLoop = CFRunLoopGetCurrent()
      guard
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
      else {
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFMachPortInvalidate(eventTap)
        finishStarting(with: .failed(.eventTapCreationFailed))
        return
      }

      let shouldStop = withSharedState { state in
        state.eventTap = eventTap
        state.runLoop = runLoop
        state.starting = false
        return state.stopRequested
      }

      guard !shouldStop else {
        cleanUpEventLoop(eventTap: eventTap, source: runLoopSource)
        emitHealth(.stopped)
        return
      }

      initializeInputState()
      CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
      if let runLoop {
        startKeyboardTopologyObservation(on: runLoop)
      }
      CGEvent.tapEnable(tap: eventTap, enable: true)
      emitHealth(.running)
      CFRunLoopRun()

      let terminalHealth = withSharedState(\.terminalHealth)
      cleanUpEventLoop(eventTap: eventTap, source: runLoopSource)
      emitHealth(terminalHealth ?? .stopped)
    }
  }

  private func cleanUpEventLoop(
    eventTap: CFMachPort,
    source: CFRunLoopSource
  ) {
    classifier.receive(.continuityLost)
    cancelCalibrationPress()
    fnDown = false
    otherKeysDown.removeAll(keepingCapacity: true)

    let runLoop = CFRunLoopGetCurrent()
    if let runLoop {
      stopKeyboardTopologyObservation(on: runLoop)
    }
    CFRunLoopRemoveSource(runLoop, source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: false)
    CFMachPortInvalidate(eventTap)

    withSharedState { state in
      state.eventTap = nil
      state.runLoop = nil
      state.starting = false
      state.stopRequested = false
      state.terminalHealth = nil
    }
  }

  private func finishStarting(with health: Health) {
    withSharedState { state in
      state.starting = false
      state.terminalHealth = nil
    }
    emitHealth(health)
  }

  /// Installs callbacks without creating an event tap, so tests can drive
  /// `receive(type:event:)` with synthesized events.
  func installCallbacksWithoutEventTap(
    onTap: @escaping @Sendable (GlobeTap) -> Void,
    onCalibrationEvent: @escaping @Sendable (CalibrationEvent) -> Void
  ) {
    withSharedState {
      $0.callbacks = Callbacks(
        onTap: onTap,
        onGlobeInput: { _ in },
        onCalibrationEvent: onCalibrationEvent,
        onHealthChange: { _ in },
        onKeyboardTopologyChange: {}
      )
    }
  }

  func receive(type: CGEventType, event: CGEvent) {
    let configuration = withSharedState {
      (
        threshold: $0.thresholdMilliseconds,
        calibrationEnabled: $0.calibrationEnabled,
        calibrationGeneration: $0.calibrationGeneration
      )
    }
    let calibrationState = (
      enabled: configuration.calibrationEnabled,
      generation: configuration.calibrationGeneration
    )
    if calibrationGeneration != calibrationState.generation {
      calibrationStartTimestamp = nil
      calibrationGeneration = calibrationState.generation
    }
    if !calibrationState.enabled {
      calibrationStartTimestamp = nil
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      cancelCalibrationPress()
      handleTapDisablement()
      return
    }

    let currentFnDown = event.flags.contains(.maskSecondaryFn)
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged, keyCode == Self.globeKeyCode {
      withSharedState(\.callbacks)?.onGlobeInput(
        currentFnDown
          ? .down(blockingInput: blockingInputDescription(in: event.flags))
          : .up
      )
    }

    // Fn changing on anything but a Globe flags event is a missing edge.
    if type != .flagsChanged || keyCode != Self.globeKeyCode,
      currentFnDown != fnDown
    {
      cancelCalibrationPress()
      classifier.receive(
        currentFnDown ? .fnAppearedOnNonModifierEvent : .continuityLost
      )
      fnDown = currentFnDown
    }

    switch type {
    case .flagsChanged:
      receiveFlagsChanged(
        timestamp: event.timestamp,
        keyCode: keyCode,
        flags: event.flags,
        currentFnDown: currentFnDown,
        thresholdMilliseconds: configuration.threshold
      )

    case .keyDown:
      cancelCalibrationPress()
      guard keyCode <= Self.maximumKeyCode else { return }
      guard keyCode != Self.globeKeyCode else {
        classifier.receive(.continuityLost)
        return
      }
      otherKeysDown.insert(keyCode)
      classifier.receive(.otherInput)

    case .keyUp:
      cancelCalibrationPress()
      guard keyCode <= Self.maximumKeyCode else { return }
      classifier.receive(.otherInput)
      otherKeysDown.remove(keyCode)

    case _ where type.rawValue == Self.systemDefinedEventTypeRawValue:
      cancelCalibrationPress()
      classifier.receive(.otherInput)

    default:
      break
    }
  }

  private func initializeInputState() {
    fnDown = CGEventSource.flagsState(.combinedSessionState)
      .contains(.maskSecondaryFn)
    otherKeysDown = Set(
      (0...Self.maximumKeyCode).compactMap { keyCode -> Int64? in
        let keyCode = Int64(keyCode)
        guard keyCode != Self.globeKeyCode else { return nil }
        return CGEventSource.keyState(
          .combinedSessionState,
          key: CGKeyCode(keyCode)
        ) ? keyCode : nil
      }
    )
  }

  private func startKeyboardTopologyObservation(on runLoop: CFRunLoop) {
    let manager = IOHIDManagerCreate(
      kCFAllocatorDefault,
      IOOptionBits(kIOHIDOptionsTypeNone)
    )
    let matching: [String: Int] = [
      kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
      kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(
      manager,
      Self.keyboardMatchedCallback,
      context
    )
    IOHIDManagerRegisterDeviceRemovalCallback(
      manager,
      Self.keyboardRemovedCallback,
      context
    )
    IOHIDManagerScheduleWithRunLoop(
      manager,
      runLoop,
      CFRunLoopMode.commonModes.rawValue
    )
    guard
      IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        == kIOReturnSuccess
    else {
      IOHIDManagerUnscheduleFromRunLoop(
        manager,
        runLoop,
        CFRunLoopMode.commonModes.rawValue
      )
      return
    }

    if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
      keyboardDevices = Set(devices.map(ObjectIdentifier.init))
    }
    hidManager = manager
    topologyCallbacksEnabled = true
  }

  private func stopKeyboardTopologyObservation(on runLoop: CFRunLoop) {
    topologyCallbacksEnabled = false
    keyboardDevices.removeAll(keepingCapacity: true)
    guard let hidManager else { return }
    IOHIDManagerUnscheduleFromRunLoop(
      hidManager,
      runLoop,
      CFRunLoopMode.commonModes.rawValue
    )
    IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
    self.hidManager = nil
  }

  private func receiveKeyboardDevice(
    _ device: IOHIDDevice,
    connected: Bool
  ) {
    let id = ObjectIdentifier(device)
    let changed =
      connected
      ? keyboardDevices.insert(id).inserted
      : keyboardDevices.remove(id) != nil
    guard topologyCallbacksEnabled, changed else { return }
    withSharedState(\.callbacks)?.onKeyboardTopologyChange()
  }

  private func receiveFlagsChanged(
    timestamp: UInt64,
    keyCode: Int64,
    flags: CGEventFlags,
    currentFnDown: Bool,
    thresholdMilliseconds: Int
  ) {
    guard keyCode == Self.globeKeyCode else {
      cancelCalibrationPress()
      classifier.receive(.otherInput)
      fnDown = currentFnDown
      return
    }

    guard currentFnDown != fnDown else {
      cancelCalibrationPress()
      if currentFnDown {
        classifier.receive(
          .globeDown(
            timestamp: timestamp,
            thresholdMilliseconds: thresholdMilliseconds,
            otherInputHeld: true
          )
        )
      } else {
        if let tap = classifier.receive(.globeUp(timestamp: timestamp)) {
          emitTap(tap)
        }
      }
      return
    }

    if currentFnDown {
      let otherInputHeld =
        !otherKeysDown.isEmpty || hasOtherModifier(in: flags)
      if otherInputHeld {
        cancelCalibrationPress()
      } else {
        beginCalibrationPress(at: timestamp)
      }
      classifier.receive(
        .globeDown(
          timestamp: timestamp,
          thresholdMilliseconds: thresholdMilliseconds,
          otherInputHeld: otherInputHeld
        )
      )
    } else {
      if !otherKeysDown.isEmpty || hasOtherModifier(in: flags) {
        cancelCalibrationPress()
        classifier.receive(.otherInput)
      } else {
        endCalibrationPress(at: timestamp)
      }
      if let tap = classifier.receive(.globeUp(timestamp: timestamp)) {
        emitTap(tap)
      }
    }

    fnDown = currentFnDown
  }

  private func hasOtherModifier(in flags: CGEventFlags) -> Bool {
    !flags.intersection(Self.heldModifierMask).isEmpty
  }

  private func blockingInputDescription(in flags: CGEventFlags) -> String? {
    var inputs: [String] = []

    if flags.contains(.maskShift) {
      inputs.append("Shift")
    }
    if flags.contains(.maskControl) {
      inputs.append("Control")
    }
    if flags.contains(.maskAlternate) {
      inputs.append("Option")
    }
    if flags.contains(.maskCommand) {
      inputs.append("Command")
    }
    if flags.contains(.maskHelp) {
      inputs.append("Help")
    }
    inputs += otherKeysDown.sorted().map { "key code \($0)" }

    return inputs.isEmpty ? nil : inputs.joined(separator: ", ")
  }

  private func handleTapDisablement() {
    cancelCalibrationPress()
    classifier.receive(.continuityLost)

    if disablementHistory.recordIsRepeated(
      at: DispatchTime.now().uptimeNanoseconds
    ) {
      stopEventLoop(with: .failed(.repeatedEventTapDisablement))
      return
    }

    guard let eventTap = withSharedState(\.eventTap) else {
      stopEventLoop(with: .failed(.eventTapCouldNotBeReenabled))
      return
    }
    CGEvent.tapEnable(tap: eventTap, enable: true)
    guard CGEvent.tapIsEnabled(tap: eventTap) else {
      stopEventLoop(with: .failed(.eventTapCouldNotBeReenabled))
      return
    }
    initializeInputState()
    emitHealth(.running)
  }

  private func stopEventLoop(with health: Health) {
    withSharedState { state in
      state.terminalHealth = health
    }
    CFRunLoopStop(CFRunLoopGetCurrent())
  }

  private var calibrationEnabled: Bool {
    withSharedState(\.calibrationEnabled)
  }

  private func beginCalibrationPress(at timestamp: UInt64) {
    guard calibrationEnabled else {
      calibrationStartTimestamp = nil
      return
    }
    calibrationStartTimestamp = timestamp
    emitCalibrationEvent(.pressBegan(timestamp: timestamp))
  }

  private func endCalibrationPress(at timestamp: UInt64) {
    guard let start = calibrationStartTimestamp else { return }
    calibrationStartTimestamp = nil
    guard timestamp >= start else {
      emitCalibrationEvent(.cancelled)
      return
    }
    emitCalibrationEvent(
      .pressEnded(
        durationMilliseconds: Double(timestamp - start) / 1_000_000
      )
    )
  }

  private func cancelCalibrationPress() {
    guard calibrationStartTimestamp != nil else { return }
    calibrationStartTimestamp = nil
    emitCalibrationEvent(.cancelled)
  }

  private func emitTap(_ tap: GlobeTap) {
    withSharedState(\.callbacks)?.onTap(tap)
  }

  private func emitCalibrationEvent(_ event: CalibrationEvent) {
    guard calibrationEnabled else { return }
    withSharedState(\.callbacks)?.onCalibrationEvent(event)
  }

  private func emitHealth(_ health: Health) {
    withSharedState(\.callbacks)?.onHealthChange(health)
  }

  private func withSharedState<Result>(
    _ body: (inout SharedState) -> Result
  ) -> Result {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body(&sharedState)
  }

  private func withSharedState<Result>(
    _ keyPath: KeyPath<SharedState, Result>
  ) -> Result {
    withSharedState { $0[keyPath: keyPath] }
  }
}

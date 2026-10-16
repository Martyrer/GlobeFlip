import AppKit
import Carbon
import Combine
import Foundation
import GlobeFlipCore

struct InputSourceItem: Identifiable, Equatable, Sendable {
  let id: String
  let localizedName: String
}

struct InputSourceSnapshot: Equatable, Sendable {
  enum Health: Equatable, Sendable {
    case ready
    case insufficientSources
    case selectionFailed
    case conflict
  }

  var sources: [InputSourceItem]
  var activeSourceID: String?
  var health: Health

  static let empty = InputSourceSnapshot(
    sources: [],
    activeSourceID: nil,
    health: .insufficientSources
  )
}

struct InputSourceSwitchResult: Equatable, Sendable {
  enum Failure: Equatable, Sendable {
    case cancelled
    case insufficientSources
    case sourceStateUnhealthy
    case targetUnavailable
    case selectionRejected(OSStatus)
    case confirmationTimedOut
  }

  let latencyMilliseconds: Double?
  let failure: Failure?

  static func confirmed(
    latencyMilliseconds: Double
  ) -> Self {
    Self(
      latencyMilliseconds: latencyMilliseconds,
      failure: nil
    )
  }

  static func failed(_ failure: Failure) -> Self {
    Self(latencyMilliseconds: nil, failure: failure)
  }
}

@MainActor
final class InputSourceManager: ObservableObject {
  private struct LiveSource {
    let item: InputSourceItem
    let reference: TISInputSource?
  }

  private struct TestOperations {
    let discoverSources: () -> [InputSourceItem]
    let currentSourceID: () -> String?
    let selectSource: (String) -> OSStatus
  }

  enum NotificationKind: Sendable {
    case selectedSourceChanged
    case enabledSourcesChanged
  }

  @Published private(set) var snapshot: InputSourceSnapshot = .empty

  private let preferences: PreferencesStore
  private let testOperations: TestOperations?
  private let now: () -> UInt64
  private var liveSourcesByID: [String: LiveSource] = [:]
  private var displacementDetector = InputSourceDisplacementDetector()
  private var displacementCheckTask: Task<Void, Never>?
  private var conflictDetected = false
  private var selectionFailureDetected = false

  init(preferences: PreferencesStore) {
    self.preferences = preferences
    testOperations = nil
    now = { DispatchTime.now().uptimeNanoseconds }
    refresh()
    installNotifications()
  }

  init(
    preferences: PreferencesStore,
    discoverSources: @escaping () -> [InputSourceItem],
    currentSourceID: @escaping () -> String?,
    selectSource: @escaping (String) -> OSStatus,
    now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) {
    self.preferences = preferences
    testOperations = TestOperations(
      discoverSources: discoverSources,
      currentSourceID: currentSourceID,
      selectSource: selectSource
    )
    self.now = now
    refresh()
  }

  deinit {
    displacementCheckTask?.cancel()
    CFNotificationCenterRemoveEveryObserver(
      CFNotificationCenterGetDistributedCenter(),
      Unmanaged.passUnretained(self).toOpaque()
    )
  }

  func refresh() {
    let discovered = discoverSources()
    let discoveredIDs = discovered.map(\.item.id)
    let reconciledOrder = InputSourceCycle.reconciledOrder(
      persistedOrder: preferences.sourceOrder,
      discoveredIDs: discoveredIDs
    )

    if preferences.sourceOrder != reconciledOrder {
      preferences.sourceOrder = reconciledOrder
    }

    liveSourcesByID = Dictionary(
      uniqueKeysWithValues: discovered.map { ($0.item.id, $0) }
    )
    let effectiveOrder = InputSourceCycle.effectiveOrder(
      persistedOrder: reconciledOrder,
      discoveredIDs: discoveredIDs
    )
    let sources = effectiveOrder.compactMap { liveSourcesByID[$0]?.item }
    snapshot = InputSourceSnapshot(
      sources: sources,
      activeSourceID: currentSourceID(),
      health:
        conflictDetected
        ? .conflict
        : selectionFailureDetected
          ? .selectionFailed
          : sources.count >= 2 ? .ready : .insufficientSources
    )
  }

  func recover() {
    conflictDetected = false
    selectionFailureDetected = false
    cancelDisplacementWatch()
    refresh()
  }

  func cancelDisplacementWatch() {
    displacementDetector.cancel()
    displacementCheckTask?.cancel()
    displacementCheckTask = nil
  }

  func moveSource(id: String, by offset: Int) {
    let effectiveIDs = snapshot.sources.map(\.id)
    guard let index = effectiveIDs.firstIndex(of: id) else { return }
    let destination = index + offset
    guard effectiveIDs.indices.contains(destination) else { return }

    let destinationID = effectiveIDs[destination]
    var persistedOrder = preferences.sourceOrder
    guard let sourceIndex = persistedOrder.firstIndex(of: id),
      let destinationIndex = persistedOrder.firstIndex(of: destinationID)
    else {
      return
    }

    persistedOrder.swapAt(sourceIndex, destinationIndex)
    preferences.sourceOrder = persistedOrder
    refresh()
  }

  func switchToNextSource(
    for intent: SwitchIntent
  ) async -> InputSourceSwitchResult {
    cancelDisplacementWatch()
    guard !Task.isCancelled else {
      return .failed(.cancelled)
    }
    guard let deadline = intent.confirmationDeadline,
      SwitchIntent.remainingNanoseconds(
        until: deadline,
        at: now()
      ) != nil
    else {
      return .failed(.confirmationTimedOut)
    }
    guard snapshot.health == .ready else {
      return .failed(
        snapshot.health == .insufficientSources
          ? .insufficientSources
          : .sourceStateUnhealthy
      )
    }

    let effectiveOrder = snapshot.sources.map(\.id)
    guard
      let targetID = InputSourceCycle.nextID(
        effectiveOrder: effectiveOrder,
        activeID: currentSourceID()
      ),
      var target = liveSourcesByID[targetID]
    else {
      return .failed(.insufficientSources)
    }

    var refreshedAfterFailure = false
    var status = selectSource(target)
    if status != noErr {
      refresh()
      refreshedAfterFailure = true
      guard snapshot.health == .ready, snapshot.sources.count >= 2 else {
        return .failed(.sourceStateUnhealthy)
      }
      guard let refreshedTarget = liveSourcesByID[targetID] else {
        return .failed(.targetUnavailable)
      }
      guard
        SwitchIntent.remainingNanoseconds(
          until: deadline,
          at: now()
        ) != nil
      else {
        return .failed(.confirmationTimedOut)
      }

      target = refreshedTarget
      status = selectSource(target)
      guard status == noErr else {
        markSelectionFailure()
        return .failed(.selectionRejected(status))
      }
    }

    let confirmed = await confirmSelection(
      targetID: targetID,
      deadline: deadline
    )
    guard confirmed else {
      if Task.isCancelled {
        snapshot = InputSourceSnapshot(
          sources: snapshot.sources,
          activeSourceID: currentSourceID(),
          health: snapshot.health
        )
        return .failed(.cancelled)
      }
      if !refreshedAfterFailure {
        refresh()
      }
      return .failed(.confirmationTimedOut)
    }

    selectionFailureDetected = false
    snapshot = InputSourceSnapshot(
      sources: snapshot.sources,
      activeSourceID: targetID,
      health: .ready
    )
    watchForDisplacement(of: targetID)
    return .confirmed(
      latencyMilliseconds: millisecondsSince(intent.keyUpTimestamp)
    )
  }

  private func confirmSelection(
    targetID: String,
    deadline: UInt64
  ) async -> Bool {
    while true {
      guard !Task.isCancelled else { return false }
      guard
        let remaining = SwitchIntent.remainingNanoseconds(
          until: deadline,
          at: now()
        )
      else {
        return false
      }
      if currentSourceID() == targetID {
        return true
      }
      try? await Task.sleep(
        for: .nanoseconds(Int64(min(remaining, 2_000_000)))
      )
    }
  }

  private func markSelectionFailure() {
    selectionFailureDetected = true
    snapshot = InputSourceSnapshot(
      sources: snapshot.sources,
      activeSourceID: snapshot.activeSourceID,
      health: .selectionFailed
    )
  }

  private func watchForDisplacement(of targetID: String) {
    displacementDetector.watch(
      targetID: targetID,
      contextID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
      confirmedAt: now()
    )
    displacementCheckTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      self?.checkForDisplacement()
    }
  }

  private func checkForDisplacement() {
    let activeID = currentSourceID()
    guard
      displacementDetector.detect(
        activeID: activeID,
        contextID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        at: now()
      )
    else {
      snapshot = InputSourceSnapshot(
        sources: snapshot.sources,
        activeSourceID: activeID,
        health: snapshot.health
      )
      return
    }

    conflictDetected = true
    displacementCheckTask?.cancel()
    displacementCheckTask = nil
    snapshot = InputSourceSnapshot(
      sources: snapshot.sources,
      activeSourceID: activeID,
      health: .conflict
    )
  }

  private func millisecondsSince(_ timestamp: UInt64) -> Double {
    let current = now()
    guard current >= timestamp else { return 0 }
    return Double(current - timestamp) / 1_000_000
  }

  private func discoverSources() -> [LiveSource] {
    if let testOperations {
      return testOperations.discoverSources().map {
        LiveSource(item: $0, reference: nil)
      }
    }

    let filter: [CFString: Any] = [
      kTISPropertyInputSourceCategory:
        kTISCategoryKeyboardInputSource as Any,
      kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue as Any,
    ]
    guard
      let sourceList = TISCreateInputSourceList(
        filter as CFDictionary,
        false
      )
    else {
      return []
    }
    let references = sourceList.takeRetainedValue() as NSArray

    var seen = Set<String>()
    return references.compactMap { value in
      let rawReference = value as CFTypeRef
      guard CFGetTypeID(rawReference) == TISInputSourceGetTypeID() else {
        return nil
      }
      let reference = unsafeDowncast(
        rawReference,
        to: TISInputSource.self
      )
      guard let id = stringProperty(reference, kTISPropertyInputSourceID),
        seen.insert(id).inserted
      else {
        return nil
      }
      let name =
        stringProperty(reference, kTISPropertyLocalizedName) ?? id
      return LiveSource(
        item: InputSourceItem(id: id, localizedName: name),
        reference: reference
      )
    }
  }

  private func currentSourceID() -> String? {
    if let testOperations {
      return testOperations.currentSourceID()
    }
    guard
      let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    else {
      return nil
    }
    return stringProperty(source, kTISPropertyInputSourceID)
  }

  private func stringProperty(
    _ source: TISInputSource,
    _ key: CFString
  ) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else {
      return nil
    }
    let value = Unmanaged<CFTypeRef>
      .fromOpaque(pointer)
      .takeUnretainedValue()
    guard CFGetTypeID(value) == CFStringGetTypeID() else {
      return nil
    }
    return value as? String
  }

  private func selectSource(_ source: LiveSource) -> OSStatus {
    if let testOperations {
      return testOperations.selectSource(source.item.id)
    }
    guard let reference = source.reference else {
      return OSStatus(paramErr)
    }
    return TISSelectInputSource(reference)
  }

  private func installNotifications() {
    let center = CFNotificationCenterGetDistributedCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      center,
      observer,
      Self.notificationCallback,
      kTISNotifySelectedKeyboardInputSourceChanged,
      nil,
      .deliverImmediately
    )
    CFNotificationCenterAddObserver(
      center,
      observer,
      Self.notificationCallback,
      kTISNotifyEnabledKeyboardInputSourcesChanged,
      nil,
      .deliverImmediately
    )
  }

  private static let notificationCallback: CFNotificationCallback = {
    _, observer, name, _, _ in
    guard let observer, let name else { return }
    let manager = Unmanaged<InputSourceManager>
      .fromOpaque(observer)
      .takeUnretainedValue()
    let kind: NotificationKind

    if CFEqual(name.rawValue, kTISNotifyEnabledKeyboardInputSourcesChanged) {
      kind = .enabledSourcesChanged
    } else {
      kind = .selectedSourceChanged
    }

    DispatchQueue.main.async {
      manager.receiveNotification(kind)
    }
  }

  func receiveNotification(_ kind: NotificationKind) {
    switch kind {
    case .selectedSourceChanged:
      checkForDisplacement()
    case .enabledSourcesChanged:
      refresh()
    }
  }
}

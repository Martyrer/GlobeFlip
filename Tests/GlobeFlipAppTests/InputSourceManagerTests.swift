import Carbon
import Foundation
import Testing

@testable import GlobeFlip
@testable import GlobeFlipCore

@Suite("Input Source manager")
@MainActor
struct InputSourceManagerTests {
  @Test("Confirmation timeout refreshes once without retrying or latching failure")
  func timeoutDoesNotLatchFailure() async {
    let context = TestContext()
    defer { context.cleanUp() }
    var selectionCount = 0
    let manager = context.makeManager { id in
      selectionCount += 1
      if selectionCount > 1 {
        context.activeID = id
      }
      return noErr
    }
    // Each poll reads the active source, so the window passes mid-poll.
    context.onRead = {
      if selectionCount == 1 {
        context.now += 30_000_000
      }
    }
    let discoveriesBefore = context.discoveryCount

    let timedOut = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 1)
    )
    #expect(timedOut == .failed(.confirmationTimedOut))
    #expect(selectionCount == 1)
    #expect(context.discoveryCount == discoveriesBefore + 1)
    #expect(manager.snapshot.health == .ready)

    let confirmed = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 2)
    )
    #expect(confirmed.failure == nil)
    #expect(selectionCount == 2)
    #expect(manager.snapshot.activeSourceID == "b")
  }

  @Test("Confirmation polls until the target becomes active")
  func delayedConfirmation() async {
    let context = TestContext()
    defer { context.cleanUp() }
    var readsUntilActive = 0
    var selectedIDs: [String] = []
    let manager = context.makeManager { id in
      selectedIDs.append(id)
      readsUntilActive = 3
      return noErr
    }
    context.onRead = {
      guard readsUntilActive > 0 else { return }
      readsUntilActive -= 1
      if readsUntilActive == 0 {
        context.activeID = "b"
      }
    }
    let discoveriesBefore = context.discoveryCount

    let result = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 1)
    )

    #expect(result.failure == nil)
    #expect(result.latencyMilliseconds != nil)
    #expect(selectedIDs == ["b"])
    #expect(readsUntilActive == 0)
    #expect(context.discoveryCount == discoveriesBefore)
    #expect(manager.snapshot.activeSourceID == "b")
  }

  @Test("Active source outside the cycle selects the first source")
  func activeOutsideCycleSelectsFirst() async {
    let context = TestContext()
    defer { context.cleanUp() }
    context.activeID = "z"
    var selectedIDs: [String] = []
    let manager = context.makeManager { id in
      selectedIDs.append(id)
      context.activeID = id
      return noErr
    }

    _ = await manager.switchToNextSource(for: context.intent(sequenceNumber: 1))

    #expect(selectedIDs == ["a"])
  }

  @Test("Last source in the cycle wraps to the first")
  func cycleWraps() async {
    let context = TestContext()
    defer { context.cleanUp() }
    context.sources.append(InputSourceItem(id: "c", localizedName: "C"))
    context.activeID = "c"
    var selectedIDs: [String] = []
    let manager = context.makeManager { id in
      selectedIDs.append(id)
      context.activeID = id
      return noErr
    }

    _ = await manager.switchToNextSource(for: context.intent(sequenceNumber: 1))
    _ = await manager.switchToNextSource(for: context.intent(sequenceNumber: 2))

    #expect(selectedIDs == ["a", "b"])
  }

  @Test("Retry keeps original target and refreshes once")
  func retryKeepsTarget() async {
    let context = TestContext()
    defer { context.cleanUp() }
    var selectedIDs: [String] = []
    let manager = context.makeManager { id in
      selectedIDs.append(id)
      if selectedIDs.count == 1 {
        return OSStatus(-1)
      }
      context.activeID = id
      return noErr
    }
    let discoveriesBefore = context.discoveryCount

    let result = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 1)
    )

    #expect(result.failure == nil)
    #expect(selectedIDs == ["b", "b"])
    #expect(context.discoveryCount == discoveriesBefore + 1)
    #expect(manager.snapshot.health == .ready)
  }

  @Test("Missing retry target fails without changing target")
  func retryTargetUnavailable() async {
    let context = TestContext()
    defer { context.cleanUp() }
    var selectedIDs: [String] = []
    let manager = context.makeManager { id in
      selectedIDs.append(id)
      context.sources = [
        InputSourceItem(id: "a", localizedName: "A"),
        InputSourceItem(id: "c", localizedName: "C"),
      ]
      return OSStatus(-1)
    }

    let result = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 1)
    )

    #expect(result == .failed(.targetUnavailable))
    #expect(selectedIDs == ["b"])
    #expect(manager.snapshot.health == .ready)
    #expect(manager.snapshot.sources.map(\.id) == ["a", "c"])
  }

  @Test("Retry is abandoned when the refresh leaves too few sources")
  func retryWithInsufficientSources() async {
    let context = TestContext()
    defer { context.cleanUp() }
    var selectedIDs: [String] = []
    let manager = context.makeManager { id in
      selectedIDs.append(id)
      context.sources = [InputSourceItem(id: "a", localizedName: "A")]
      return OSStatus(-1)
    }

    let result = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 1)
    )

    #expect(result == .failed(.sourceStateUnhealthy))
    #expect(selectedIDs == ["b"])
    #expect(manager.snapshot.health == .insufficientSources)
  }

  @Test("Retry is skipped once the confirmation deadline has passed")
  func retryAfterDeadline() async {
    let context = TestContext()
    defer { context.cleanUp() }
    let intent = context.intent(sequenceNumber: 1)
    var selectedIDs: [String] = []
    let manager = context.makeManager { id in
      selectedIDs.append(id)
      context.now = intent.confirmationDeadline!
      return OSStatus(-1)
    }

    let result = await manager.switchToNextSource(for: intent)

    #expect(result == .failed(.confirmationTimedOut))
    #expect(selectedIDs == ["b"])
  }

  @Test("Expired intent never selects")
  func expiredIntentDoesNotSelect() async {
    let context = TestContext()
    defer { context.cleanUp() }
    var selectionCount = 0
    let manager = context.makeManager { _ in
      selectionCount += 1
      return noErr
    }

    let result = await manager.switchToNextSource(
      for: SwitchIntent(sequenceNumber: 1, keyUpTimestamp: 0)
    )

    #expect(result == .failed(.confirmationTimedOut))
    #expect(selectionCount == 0)
  }

  @Test("Cancellation during confirmation ends the intent without refreshing")
  func cancellationDuringConfirmation() async {
    let context = TestContext()
    defer { context.cleanUp() }
    let selected = AsyncStream<String>.makeStream()
    let manager = context.makeManager { id in
      selected.continuation.yield(id)
      return noErr
    }
    let discoveriesBefore = context.discoveryCount

    let task = Task {
      await manager.switchToNextSource(for: context.intent(sequenceNumber: 1))
    }
    var iterator = selected.stream.makeAsyncIterator()
    #expect(await iterator.next() == "b")
    task.cancel()
    let result = await task.value

    #expect(result == .failed(.cancelled))
    #expect(context.discoveryCount == discoveriesBefore)
    #expect(manager.snapshot.health == .ready)
    #expect(manager.snapshot.activeSourceID == "a")
  }

  @Test("Rejected selection remains blocked until explicit recovery")
  func rejectedSelectionRequiresRecovery() async {
    let context = TestContext()
    defer { context.cleanUp() }
    var shouldReject = true
    var selectionCount = 0
    let manager = context.makeManager { id in
      selectionCount += 1
      guard !shouldReject else { return OSStatus(-1) }
      context.activeID = id
      return noErr
    }
    let discoveriesBefore = context.discoveryCount

    let rejected = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 1)
    )
    #expect(rejected == .failed(.selectionRejected(-1)))
    #expect(manager.snapshot.health == .selectionFailed)
    #expect(selectionCount == 2)
    #expect(context.discoveryCount == discoveriesBefore + 1)

    shouldReject = false
    manager.refresh()
    #expect(manager.snapshot.health == .selectionFailed)
    let blocked = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 2)
    )
    #expect(blocked == .failed(.sourceStateUnhealthy))
    #expect(selectionCount == 2)

    manager.recover()
    #expect(manager.snapshot.health == .ready)
    let confirmed = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 3)
    )
    #expect(confirmed.failure == nil)
    #expect(context.activeID == "b")
  }

  @Test("Insufficient source health prevents selection")
  func insufficientSourcesPreventSelection() async {
    let context = TestContext()
    defer { context.cleanUp() }
    context.sources = [InputSourceItem(id: "a", localizedName: "A")]
    var selectionCount = 0
    let manager = context.makeManager { _ in
      selectionCount += 1
      return noErr
    }

    let result = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 1)
    )

    #expect(manager.snapshot.health == .insufficientSources)
    #expect(result == .failed(.insufficientSources))
    #expect(selectionCount == 0)
  }

  @Test("Displacement right after confirmation latches a conflict")
  func displacementLatchesConflict() async {
    let context = TestContext()
    defer { context.cleanUp() }
    var selectionCount = 0
    let manager = context.makeManager { id in
      selectionCount += 1
      context.activeID = id
      return noErr
    }
    _ = await manager.switchToNextSource(for: context.intent(sequenceNumber: 1))
    #expect(context.activeID == "b")

    context.activeID = "a"
    manager.receiveNotification(.selectedSourceChanged)
    #expect(manager.snapshot.health == .conflict)
    #expect(manager.snapshot.activeSourceID == "a")

    let blocked = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 2)
    )
    #expect(blocked == .failed(.sourceStateUnhealthy))
    #expect(selectionCount == 1)

    manager.receiveNotification(.enabledSourcesChanged)
    #expect(manager.snapshot.health == .conflict)

    manager.recover()
    #expect(manager.snapshot.health == .ready)
    let confirmed = await manager.switchToNextSource(
      for: context.intent(sequenceNumber: 3)
    )
    #expect(confirmed.failure == nil)
    #expect(selectionCount == 2)
  }

  @Test("A new GlobeFlip intent cancels the displacement watch")
  func newIntentCancelsDisplacementWatch() async {
    let context = TestContext()
    defer { context.cleanUp() }
    let manager = context.makeManager { id in
      context.activeID = id
      return noErr
    }
    _ = await manager.switchToNextSource(for: context.intent(sequenceNumber: 1))

    manager.cancelDisplacementWatch()
    context.activeID = "a"
    manager.receiveNotification(.selectedSourceChanged)

    #expect(manager.snapshot.health == .ready)
    #expect(manager.snapshot.activeSourceID == "a")
  }

  @Test("Confirmed target that stays active is not a conflict")
  func stableTargetIsNotConflict() async {
    let context = TestContext()
    defer { context.cleanUp() }
    let manager = context.makeManager { id in
      context.activeID = id
      return noErr
    }
    _ = await manager.switchToNextSource(for: context.intent(sequenceNumber: 1))

    manager.receiveNotification(.selectedSourceChanged)
    manager.receiveNotification(.selectedSourceChanged)

    #expect(manager.snapshot.health == .ready)
    #expect(manager.snapshot.activeSourceID == "b")
  }

  @Test("Enabled-sources notification rediscovers the cycle")
  func enabledSourcesNotificationRefreshes() {
    let context = TestContext()
    defer { context.cleanUp() }
    let manager = context.makeManager { _ in noErr }

    context.sources = [InputSourceItem(id: "a", localizedName: "A")]
    manager.receiveNotification(.enabledSourcesChanged)
    #expect(manager.snapshot.health == .insufficientSources)
    #expect(manager.snapshot.sources.map(\.id) == ["a"])

    context.sources = [
      InputSourceItem(id: "c", localizedName: "C"),
      InputSourceItem(id: "a", localizedName: "A"),
      InputSourceItem(id: "b", localizedName: "B"),
    ]
    manager.receiveNotification(.enabledSourcesChanged)
    #expect(manager.snapshot.health == .ready)
    #expect(manager.snapshot.sources.map(\.id) == ["a", "b", "c"])
  }

  @Test("Refresh keeps persisted order, retains ineligible IDs, and appends new IDs")
  func refreshReconcilesPersistedOrder() {
    let context = TestContext()
    defer { context.cleanUp() }
    context.preferences.sourceOrder = ["c", "x", "a"]
    context.sources.append(InputSourceItem(id: "c", localizedName: "C"))

    let manager = context.makeManager { _ in noErr }

    #expect(manager.snapshot.sources.map(\.id) == ["c", "a", "b"])
    #expect(context.preferences.sourceOrder == ["c", "x", "a", "b"])
  }

  @Test("Move swaps adjacent effective sources in persisted order")
  func moveSource() {
    let context = TestContext()
    defer { context.cleanUp() }
    context.sources.append(
      InputSourceItem(id: "c", localizedName: "C")
    )
    let manager = context.makeManager { _ in noErr }

    manager.moveSource(id: "b", by: 1)

    #expect(context.preferences.sourceOrder == ["a", "c", "b"])
    #expect(manager.snapshot.sources.map(\.id) == ["a", "c", "b"])
  }

  @Test("Move skips ineligible persisted IDs and ignores out-of-range moves")
  func moveSkipsIneligibleIDs() {
    let context = TestContext()
    defer { context.cleanUp() }
    context.preferences.sourceOrder = ["a", "x", "b"]
    let manager = context.makeManager { _ in noErr }

    manager.moveSource(id: "b", by: -1)
    #expect(context.preferences.sourceOrder == ["b", "x", "a"])
    #expect(manager.snapshot.sources.map(\.id) == ["b", "a"])

    manager.moveSource(id: "b", by: -1)
    manager.moveSource(id: "a", by: 1)
    manager.moveSource(id: "x", by: 1)
    #expect(context.preferences.sourceOrder == ["b", "x", "a"])
  }

}

@MainActor
private final class TestContext {
  let defaults: UserDefaults
  let suiteName: String
  let preferences: PreferencesStore
  var sources = [
    InputSourceItem(id: "a", localizedName: "A"),
    InputSourceItem(id: "b", localizedName: "B"),
  ]
  var activeID: String? = "a"
  var onRead: (() -> Void)?
  /// The manager's clock. It only moves when a test advances it.
  var now: UInt64 = 1_000_000_000
  private(set) var discoveryCount = 0

  init() {
    suiteName = "InputSourceManagerTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    preferences = PreferencesStore(defaults: defaults)
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
  }

  func makeManager(
    selectSource: @escaping (String) -> OSStatus
  ) -> InputSourceManager {
    InputSourceManager(
      preferences: preferences,
      discoverSources: { [weak self] in
        self?.discoveryCount += 1
        return self?.sources ?? []
      },
      currentSourceID: { [weak self] in
        self?.onRead?()
        return self?.activeID
      },
      selectSource: selectSource,
      now: { [weak self] in self?.now ?? 0 }
    )
  }

  func intent(sequenceNumber: UInt64) -> SwitchIntent {
    SwitchIntent(sequenceNumber: sequenceNumber, keyUpTimestamp: now)
  }
}

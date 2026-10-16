import Foundation
import Testing

@testable import GlobeFlip
@testable import GlobeFlipCore

@Suite("Runtime coordinator fuzz")
@MainActor
struct RuntimeCoordinatorFuzzTests {
  private enum Operation: CaseIterable {
    case tap
    case setPaused
    case finishStart
    case finishStop
    case failEventTap
    case reenableEventTap
    case checkAgain
    case restartEventTap
    case changeSources
    case changeActiveSource
    case moveSource
    case suspendLifecycle
    case resumeLifecycle
    case startCalibration
    case stopCalibration
    case setGlobeActionConfirmed
  }

  private static let universe = ["a", "b", "c", "d"]

  /// Weighted so gates reopen often enough for taps to reach selection.
  private static let weightedOperations: [Operation] = Operation.allCases.flatMap {
    operation -> [Operation] in
    switch operation {
    case .tap: Array(repeating: operation, count: 10)
    case .finishStart, .finishStop, .checkAgain, .resumeLifecycle,
      .stopCalibration, .setGlobeActionConfirmed, .changeSources:
      Array(repeating: operation, count: 3)
    case .setPaused: Array(repeating: operation, count: 2)
    default: [operation]
    }
  }

  @Test("Random runtime input never switches through a closed gate and always recovers")
  func randomRuntimeInput() async {
    let iterations = AppFuzz.iterations(default: 25)

    var randomPhaseSwitches = 0

    for iteration in 0..<iterations {
      let seed = AppFuzz.seed(forIteration: iteration)
      guard let switches = await runIteration(seed: seed) else { return }
      randomPhaseSwitches += switches
    }

    // The generator must reach confirmed switches, or the gates prove nothing.
    #expect(randomPhaseSwitches >= iterations / 4)
  }

  /// Returns the confirmed switches made by random input, or nil after
  /// recording the first violated invariant.
  private func runIteration(seed: UInt64) async -> Int? {
    var random = SplitMix64(seed: seed)
    let harness = RuntimeHarness(
      sourceIDs: Array(Self.universe.prefix(Int.random(in: 1...4, using: &random)))
    )
    defer { harness.cleanUp() }
    harness.preferences.hapticEnabled = true
    var suspended = false
    var previewHaptics = 0
    var violations: [String] = []
    var step = 0
    var operation = Operation.tap

    func check(_ condition: Bool, _ invariant: String) {
      if !condition {
        violations.append("seed \(seed) step \(step) after \(operation): \(invariant)")
      }
    }

    harness.onSelect = { target in
      let runtime = harness.runtime!
      check(!harness.preferences.switchingPaused, "selected while paused")
      check(runtime.eventMonitorHealth == .running, "selected without a running event tap")
      check(harness.monitor.state == .running, "selected while the monitor is not running")
      check(!suspended, "selected while suspended for lifecycle")
      check(!runtime.calibrationActive, "selected during calibration")
      check(harness.preferences.systemGlobeActionConfirmed, "selected before Globe action confirmation")
      check(harness.preferences.onboardingCompleted, "selected before onboarding")
      check(harness.inputSources.snapshot.health == .ready, "selected with unhealthy sources")
      check(harness.sources.contains { $0.id == target }, "selected non-eligible source \(target)")
      check(
        harness.inputSources.snapshot.sources.contains { $0.id == target },
        "selected a source outside the cycle \(target)"
      )
    }

    await harness.startRunning()

    for currentStep in 0..<40 {
      step = currentStep
      operation = Self.weightedOperations.randomElement(using: &random)!
      let startsBefore = harness.monitor.startCount
      let stopsBefore = harness.monitor.stopCount

      switch operation {
      case .tap:
        harness.selection = Self.randomSelection(&random)
        await harness.tap()
      case .setPaused:
        let paused = random.chance(0.3)
        if harness.preferences.switchingPaused != paused { previewHaptics += 1 }
        harness.runtime.setSwitchingPaused(paused)
      case .finishStart:
        harness.monitor.finishStart(
          [.running, .running, .permissionRequired, .failed(.eventTapCreationFailed)]
            .randomElement(using: &random)!
        )
      case .finishStop:
        harness.monitor.finishStop()
      case .failEventTap:
        harness.monitor.fail(
          random.chance(0.5) ? .repeatedEventTapDisablement : .eventTapCouldNotBeReenabled
        )
      case .reenableEventTap:
        harness.monitor.reenable()
      case .checkAgain:
        harness.runtime.checkAgain()
      case .restartEventTap:
        harness.runtime.restartEventTap()
      case .changeSources:
        let ids = Self.universe.shuffled(using: &random)
          .prefix(random.chance(0.2) ? Int.random(in: 0...1, using: &random) : Int.random(in: 2...4, using: &random))
        harness.setSources(Array(ids))
      case .changeActiveSource:
        harness.activeID = (harness.sources.map(\.id) + ["z"]).randomElement(using: &random)
        harness.inputSources.receiveNotification(.selectedSourceChanged)
      case .moveSource:
        harness.runtime.moveInputSource(
          id: Self.universe.randomElement(using: &random)!,
          by: random.chance(0.5) ? 1 : -1
        )
      case .suspendLifecycle:
        suspended = true
        harness.runtime.suspendForLifecycle()
      case .resumeLifecycle:
        suspended = false
        harness.runtime.resumeAfterLifecycle()
      case .startCalibration:
        harness.runtime.startCalibration()
      case .stopCalibration:
        harness.runtime.stopCalibration()
      case .setGlobeActionConfirmed:
        let confirmed = random.chance(0.8)
        if harness.preferences.systemGlobeActionConfirmed != confirmed { previewHaptics += 1 }
        harness.runtime.setSystemGlobeActionConfirmed(confirmed)
      }
      await harness.settleSwitches()

      check(harness.monitor.startCount - startsBefore <= 1, "unbounded event-tap restarts")
      check(harness.monitor.stopCount - stopsBefore <= 1, "unbounded event-tap stops")
      checkConsistency(harness, check)
      check(
        harness.hapticCount == harness.activations + previewHaptics,
        "haptics \(harness.hapticCount) without matching confirmed switches"
      )
      check(
        harness.recordedSwitchCount == harness.activations,
        "statistics do not match confirmed switches"
      )
      if !violations.isEmpty { break }
    }

    let randomPhaseSwitches = harness.activations
    if violations.isEmpty {
      step = 40
      if suspended {
        suspended = false
        harness.runtime.resumeAfterLifecycle()
      }
      await heal(harness, check)
    }
    for violation in violations {
      Issue.record(Comment(rawValue: violation))
    }
    return violations.isEmpty ? randomPhaseSwitches : nil
  }

  private func checkConsistency(
    _ harness: RuntimeHarness,
    _ check: (Bool, String) -> Void
  ) {
    let runtime: RuntimeCoordinator = harness.runtime
    let snapshot = harness.inputSources.snapshot
    let sourceIDs = snapshot.sources.map(\.id)
    let order = harness.preferences.sourceOrder

    check(runtime.switches.queueDepth == 0, "switch queue did not drain")
    check(runtime.inputSourceSnapshot == snapshot, "runtime snapshot is stale")
    check(snapshot.health != .ready || sourceIDs.count >= 2, "ready with fewer than two sources")
    check(Set(sourceIDs) == Set(harness.sources.map(\.id)), "cycle differs from eligible sources")
    check(Set(sourceIDs).count == sourceIDs.count, "duplicate sources in cycle")
    check(Set(order).count == order.count, "duplicate persisted IDs")
    check(sourceIDs == order.filter(Set(sourceIDs).contains), "cycle ignores persisted order")

    switch harness.monitor.state {
    case .running:
      check(runtime.eventMonitorHealth == .running, "running monitor reported as \(runtime.eventMonitorHealth)")
    case .starting:
      check(runtime.eventMonitorHealth == .starting, "starting monitor reported as \(runtime.eventMonitorHealth)")
    case .idle:
      check(
        runtime.eventMonitorHealth != .running && runtime.eventMonitorHealth != .starting,
        "idle monitor reported as \(runtime.eventMonitorHealth)"
      )
    }

    let warnings = harness.warnings
    let failed = if case .failed = runtime.eventMonitorHealth { true } else { false }
    check(
      warnings.contains(.inputMonitoring) == (runtime.eventMonitorHealth == .permissionRequired),
      "Input Monitoring warning out of date"
    )
    check(warnings.contains(.eventTap) == failed, "event-tap warning out of date")
    check(
      warnings.contains(.insufficientSources) == (snapshot.health == .insufficientSources),
      "insufficient-sources warning out of date"
    )
    check(
      warnings.contains(.sourceSelection) == (snapshot.health == .selectionFailed),
      "selection warning out of date"
    )
    check(
      warnings.contains(.sourceConflict) == (snapshot.health == .conflict),
      "conflict warning out of date"
    )
    check(
      warnings.contains(.systemGlobeAction) == !harness.preferences.systemGlobeActionConfirmed,
      "Globe action warning out of date"
    )
    check(!warnings.contains(.systemSettings), "unexpected System Settings warning")
  }

  /// Every reachable state must recover through the user's own actions.
  private func heal(
    _ harness: RuntimeHarness,
    _ check: (Bool, String) -> Void
  ) async {
    let runtime: RuntimeCoordinator = harness.runtime
    runtime.stopCalibration()
    runtime.setSwitchingPaused(false)
    runtime.setSystemGlobeActionConfirmed(true)
    harness.setSources(["a", "b"])
    harness.selection = .confirm
    runtime.checkAgain()
    await harness.settleMonitor()

    check(runtime.eventMonitorHealth == .running, "Check Again left \(runtime.eventMonitorHealth)")
    check(harness.warnings == [], "warnings remain after recovery: \(harness.warnings)")
    let activeBefore = harness.activeID
    let selectionsBefore = harness.selections.count
    await harness.tap()
    check(harness.selections.count == selectionsBefore + 1, "tap after recovery did not select once")
    check(harness.activeID != activeBefore, "tap after recovery did not switch")
    check(runtime.lastSwitchResult?.failure == nil, "tap after recovery failed")
  }

  private static func randomSelection(
    _ random: inout SplitMix64
  ) -> RuntimeHarness.Selection {
    switch Int.random(in: 0..<100, using: &random) {
    case 0..<50: .confirm
    case 50..<65: .rejectOnce
    case 65..<75: .rejectAlways
    case 75..<85: .neverConfirm
    default: .removeTargetAndReject
    }
  }
}

import Foundation
import GlobeFlipCore

@MainActor
final class SwitchCoordinator {
  var onCompletion: ((SwitchIntent, InputSourceSwitchResult) -> Void)?
  private(set) var queueDepth = 0

  private let switchIntent: @MainActor (SwitchIntent) async -> InputSourceSwitchResult
  private let cancelSelection: () -> Void
  private var queue: [SwitchIntent] = []
  private var activeIntent: SwitchIntent?
  private var processingTask: Task<Void, Never>?
  private var activeResultSuppressed = false
  private var nextSequenceNumber: UInt64 = 1

  init(inputSources: InputSourceManager) {
    switchIntent = inputSources.switchToNextSource(for:)
    cancelSelection = inputSources.cancelDisplacementWatch
  }

  init(
    switchIntent:
      @escaping @MainActor (SwitchIntent) async -> InputSourceSwitchResult,
    cancelSelection: @escaping () -> Void
  ) {
    self.switchIntent = switchIntent
    self.cancelSelection = cancelSelection
  }

  func enqueue(_ tap: GlobeTap) {
    cancelSelection()
    queue.append(
      SwitchIntent(
        sequenceNumber: nextSequenceNumber,
        keyUpTimestamp: tap.keyUpTimestamp
      )
    )
    nextSequenceNumber &+= 1
    publishQueueDepth()
    startProcessingIfNeeded()
  }

  /// Pass `reportingActiveFailure` only when the cancellation is a consequence
  /// of the active intent itself (source health turning unhealthy), so that
  /// intent's own failure still reaches `onCompletion`.
  func cancelAll(reportingActiveFailure: Bool = false) {
    if !reportingActiveFailure {
      activeResultSuppressed = true
    }
    cancelSelection()
    queue.removeAll(keepingCapacity: true)
    activeIntent = nil
    processingTask?.cancel()
    publishQueueDepth()
  }

  private func startProcessingIfNeeded() {
    guard processingTask == nil, !queue.isEmpty else { return }

    processingTask = Task { [weak self] in
      guard let self else { return }

      while !Task.isCancelled, !self.queue.isEmpty {
        let intent = self.queue.removeFirst()
        self.activeIntent = intent
        self.activeResultSuppressed = false
        self.publishQueueDepth()

        let result = await self.switchIntent(intent)
        // A failure can cancel the queue from inside its own intent (the
        // source health turns unhealthy); still report that failure, but
        // nothing at all after an explicit cancelAll().
        let failedOnItsOwn =
          !self.activeResultSuppressed
          && result.failure != nil && result.failure != .cancelled
        if !Task.isCancelled || failedOnItsOwn {
          self.onCompletion?(intent, result)
        }

        self.activeIntent = nil
        self.publishQueueDepth()
      }

      self.processingTask = nil
      self.publishQueueDepth()
      if !self.queue.isEmpty {
        self.startProcessingIfNeeded()
      }
    }
  }

  private func publishQueueDepth() {
    queueDepth = queue.count + (activeIntent == nil ? 0 : 1)
  }
}

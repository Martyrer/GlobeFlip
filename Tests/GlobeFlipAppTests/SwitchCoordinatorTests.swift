import Testing

@testable import GlobeFlip
@testable import GlobeFlipCore

@Suite("Switch coordinator")
@MainActor
struct SwitchCoordinatorTests {
  @Test("Processes intents FIFO with one selection in flight")
  func fifo() async {
    var processed: [UInt64] = []
    var timestamps: [UInt64] = []
    var completed: [UInt64] = []
    var inFlight = 0
    var maximumInFlight = 0
    var cancellationCount = 0
    let completionEvents = AsyncStream<UInt64>.makeStream()
    await confirmation(expectedCount: 3) { completedIntent in
      let coordinator = SwitchCoordinator(
        switchIntent: { intent in
          inFlight += 1
          maximumInFlight = max(maximumInFlight, inFlight)
          processed.append(intent.sequenceNumber)
          timestamps.append(intent.keyUpTimestamp)
          await Task.yield()
          inFlight -= 1
          return .confirmed(latencyMilliseconds: 1)
        },
        cancelSelection: {
          cancellationCount += 1
        }
      )
      coordinator.onCompletion = { intent, _ in
        completionEvents.continuation.yield(intent.sequenceNumber)
        completedIntent()
      }

      for timestamp in [UInt64(10), 20, 30] {
        coordinator.enqueue(
          GlobeTap(keyUpTimestamp: timestamp, thresholdMilliseconds: 150)
        )
      }

      var iterator = completionEvents.stream.makeAsyncIterator()
      for _ in 0..<3 {
        if let sequenceNumber = await iterator.next() {
          completed.append(sequenceNumber)
        }
      }

      #expect(processed == [1, 2, 3])
      #expect(timestamps == [10, 20, 30])
      #expect(completed == [1, 2, 3])
      #expect(maximumInFlight == 1)
      #expect(coordinator.queueDepth == 0)
      #expect(cancellationCount == 3)
    }
  }

  @Test("Cancellation drops old intents and permits a later sequence")
  func cancellation() async {
    var completed: [UInt64] = []
    var cancellationCount = 0
    let invocationEvents = AsyncStream<UInt64>.makeStream()
    let completionEvents = AsyncStream<UInt64>.makeStream()

    await confirmation(expectedCount: 1) { completedIntent in
      let coordinator = SwitchCoordinator(
        switchIntent: { intent in
          invocationEvents.continuation.yield(intent.sequenceNumber)
          if intent.sequenceNumber == 1 {
            do {
              try await Task.sleep(for: .seconds(1))
            } catch {
              return .failed(.cancelled)
            }
          }
          return .confirmed(latencyMilliseconds: 1)
        },
        cancelSelection: {
          cancellationCount += 1
        }
      )
      coordinator.onCompletion = { intent, _ in
        completed.append(intent.sequenceNumber)
        completionEvents.continuation.yield(intent.sequenceNumber)
        completedIntent()
      }

      coordinator.enqueue(
        GlobeTap(keyUpTimestamp: 10, thresholdMilliseconds: 150)
      )
      coordinator.enqueue(
        GlobeTap(keyUpTimestamp: 20, thresholdMilliseconds: 150)
      )

      var invocationIterator = invocationEvents.stream.makeAsyncIterator()
      #expect(await invocationIterator.next() == 1)
      coordinator.cancelAll()

      coordinator.enqueue(
        GlobeTap(keyUpTimestamp: 30, thresholdMilliseconds: 150)
      )
      #expect(await invocationIterator.next() == 3)

      var completionIterator = completionEvents.stream.makeAsyncIterator()
      #expect(await completionIterator.next() == 3)
      #expect(coordinator.queueDepth == 0)
      #expect(completed == [3])
      #expect(cancellationCount == 4)
    }
  }

  @Test("Queue depth counts waiting and in-flight intents; late results after cancellation are dropped")
  func queueDepthAndLateResults() async {
    var pending: [CheckedContinuation<Void, Never>] = []
    var completed: [UInt64] = []
    let started = AsyncStream<UInt64>.makeStream()
    let coordinator = SwitchCoordinator(
      switchIntent: { intent in
        started.continuation.yield(intent.sequenceNumber)
        await withCheckedContinuation { pending.append($0) }
        return .confirmed(latencyMilliseconds: 1)
      },
      cancelSelection: {}
    )
    coordinator.onCompletion = { intent, _ in
      completed.append(intent.sequenceNumber)
    }
    var startedIterator = started.stream.makeAsyncIterator()

    for timestamp in [UInt64(10), 20, 30] {
      coordinator.enqueue(
        GlobeTap(keyUpTimestamp: timestamp, thresholdMilliseconds: 150)
      )
    }
    #expect(coordinator.queueDepth == 3)
    #expect(await startedIterator.next() == 1)
    #expect(coordinator.queueDepth == 3)

    pending.removeFirst().resume()
    #expect(await startedIterator.next() == 2)
    #expect(completed == [1])
    #expect(coordinator.queueDepth == 2)

    coordinator.cancelAll()
    #expect(coordinator.queueDepth == 0)
    // Intent 2 ignores cancellation and reports success anyway.
    pending.removeFirst().resume()
    coordinator.enqueue(
      GlobeTap(keyUpTimestamp: 40, thresholdMilliseconds: 150)
    )
    #expect(await startedIterator.next() == 4)
    pending.removeFirst().resume()
    for _ in 0..<100 where coordinator.queueDepth > 0 {
      await Task.yield()
    }

    #expect(completed == [1, 4])
    #expect(pending.isEmpty)
  }

  @Test("A failure that cancels its own queue is still reported")
  func selfCancellingFailureIsReported() async {
    var invoked: [UInt64] = []
    var results: [UInt64: InputSourceSwitchResult] = [:]
    var coordinator: SwitchCoordinator?
    coordinator = SwitchCoordinator(
      switchIntent: { intent in
        invoked.append(intent.sequenceNumber)
        // Source health turning unhealthy cancels the queue synchronously.
        coordinator?.cancelAll(reportingActiveFailure: true)
        return .failed(.selectionRejected(-1))
      },
      cancelSelection: {}
    )
    coordinator?.onCompletion = { intent, result in
      results[intent.sequenceNumber] = result
    }

    coordinator?.enqueue(GlobeTap(keyUpTimestamp: 10, thresholdMilliseconds: 150))
    coordinator?.enqueue(GlobeTap(keyUpTimestamp: 20, thresholdMilliseconds: 150))
    for _ in 0..<100 {
      await Task.yield()
    }

    #expect(invoked == [1])
    #expect(results == [1: .failed(.selectionRejected(-1))])
  }

  @Test("A failure arriving after an explicit cancelAll is not reported")
  func failureAfterExplicitCancellationIsDropped() async {
    var pending: CheckedContinuation<Void, Never>?
    var completed: [UInt64] = []
    let started = AsyncStream<UInt64>.makeStream()
    let coordinator = SwitchCoordinator(
      switchIntent: { intent in
        started.continuation.yield(intent.sequenceNumber)
        await withCheckedContinuation { pending = $0 }
        return .failed(.selectionRejected(-1))
      },
      cancelSelection: {}
    )
    coordinator.onCompletion = { intent, _ in
      completed.append(intent.sequenceNumber)
    }
    var startedIterator = started.stream.makeAsyncIterator()

    coordinator.enqueue(GlobeTap(keyUpTimestamp: 10, thresholdMilliseconds: 150))
    #expect(await startedIterator.next() == 1)
    // A health-driven cancellation followed by an explicit one (for example
    // Pause) must still suppress the late failure.
    coordinator.cancelAll(reportingActiveFailure: true)
    coordinator.cancelAll()
    pending?.resume()
    for _ in 0..<100 {
      await Task.yield()
    }

    #expect(completed.isEmpty)
    #expect(coordinator.queueDepth == 0)
  }
}

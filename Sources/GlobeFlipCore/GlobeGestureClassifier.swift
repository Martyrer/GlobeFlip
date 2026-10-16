public struct GlobeTap: Equatable, Sendable {
  public let keyUpTimestamp: UInt64
  public let thresholdMilliseconds: Int

  public init(keyUpTimestamp: UInt64, thresholdMilliseconds: Int) {
    self.keyUpTimestamp = keyUpTimestamp
    self.thresholdMilliseconds = thresholdMilliseconds
  }
}

public struct GlobeGestureClassifier: Sendable {
  public enum State: Equatable, Sendable {
    case idle
    case tapCandidate(
      startTimestamp: UInt64,
      thresholdMilliseconds: Int
    )
    case fnPassThrough
  }

  public enum Input: Equatable, Sendable {
    case globeDown(
      timestamp: UInt64,
      thresholdMilliseconds: Int,
      otherInputHeld: Bool
    )
    case globeUp(timestamp: UInt64)
    case fnAppearedOnNonModifierEvent
    case otherInput
    case continuityLost
  }

  public private(set) var state: State = .idle

  public init() {}

  @discardableResult
  public mutating func receive(_ input: Input) -> GlobeTap? {
    switch input {
    case .globeDown(let timestamp, let thresholdMilliseconds, let otherInputHeld):
      guard case .idle = state else {
        state = .fnPassThrough
        return nil
      }

      state =
        otherInputHeld
        ? .fnPassThrough
        : .tapCandidate(
          startTimestamp: timestamp,
          thresholdMilliseconds: thresholdMilliseconds
        )

    case .globeUp(let timestamp):
      defer { state = .idle }
      guard case .tapCandidate(let start, let threshold) = state,
        threshold >= 0,
        timestamp >= start,
        (timestamp - start) / 1_000_000 < UInt64(threshold)
      else {
        return nil
      }
      return GlobeTap(
        keyUpTimestamp: timestamp,
        thresholdMilliseconds: threshold
      )

    case .fnAppearedOnNonModifierEvent:
      state = .fnPassThrough

    case .otherInput:
      if case .tapCandidate = state {
        state = .fnPassThrough
      }

    case .continuityLost:
      state = .idle
    }

    return nil
  }
}

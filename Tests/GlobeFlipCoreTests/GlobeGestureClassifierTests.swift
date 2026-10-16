import Testing

@testable import GlobeFlipCore

@Suite
struct GlobeGestureClassifierTests {
  @Test
  func testCleanTapBelowThresholdProducesTap() {
    var classifier = GlobeGestureClassifier()

    classifier.receive(
      .globeDown(
        timestamp: 1_000_000_000,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )
    let tap = classifier.receive(.globeUp(timestamp: 1_149_999_999))

    #expect(
      tap
        == GlobeTap(
          keyUpTimestamp: 1_149_999_999,
          thresholdMilliseconds: 150
        )
    )
    #expect(classifier.state == .idle)
  }

  @Test
  func testTapAtThresholdIsHold() {
    var classifier = GlobeGestureClassifier()

    classifier.receive(
      .globeDown(
        timestamp: 1_000_000_000,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )

    #expect(classifier.receive(.globeUp(timestamp: 1_150_000_000)) == nil)
    #expect(classifier.state == .idle)
  }

  @Test
  func testNegativeThresholdFailsOpen() {
    var classifier = GlobeGestureClassifier()

    classifier.receive(
      .globeDown(
        timestamp: 0,
        thresholdMilliseconds: -1,
        otherInputHeld: false
      )
    )
    let tap = classifier.receive(.globeUp(timestamp: 1))

    #expect(tap == nil)
    #expect(classifier.state == .idle)
  }

  @Test
  func testThresholdIsSnapshottedAtGlobeDown() {
    var classifier = GlobeGestureClassifier()

    classifier.receive(
      .globeDown(
        timestamp: 0,
        thresholdMilliseconds: 200,
        otherInputHeld: false
      )
    )
    let tap = classifier.receive(.globeUp(timestamp: 175_000_000))

    #expect(tap == GlobeTap(keyUpTimestamp: 175_000_000, thresholdMilliseconds: 200))

    // The same 175 ms press is a hold under the next press's own snapshot.
    classifier.receive(
      .globeDown(
        timestamp: 1_000_000_000,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )
    #expect(classifier.receive(.globeUp(timestamp: 1_175_000_000)) == nil)
  }

  @Test
  func testAnotherInputHeldPreventsCandidate() {
    var classifier = GlobeGestureClassifier()

    classifier.receive(
      .globeDown(
        timestamp: 0,
        thresholdMilliseconds: 150,
        otherInputHeld: true
      )
    )

    #expect(classifier.state == .fnPassThrough)
    #expect(classifier.receive(.globeUp(timestamp: 20_000_000)) == nil)
    #expect(classifier.state == .idle)
  }

  @Test
  func testAnotherInputJoiningCandidateCancelsTap() {
    var classifier = GlobeGestureClassifier()
    classifier.receive(
      .globeDown(
        timestamp: 0,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )

    classifier.receive(.otherInput)

    #expect(classifier.state == .fnPassThrough)
    #expect(classifier.receive(.globeUp(timestamp: 20_000_000)) == nil)
  }

  @Test
  func testContinuityLossClearsCandidate() {
    var classifier = GlobeGestureClassifier()
    classifier.receive(
      .globeDown(
        timestamp: 0,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )

    classifier.receive(.continuityLost)

    #expect(classifier.state == .idle)
    #expect(classifier.receive(.globeUp(timestamp: 20_000_000)) == nil)
  }

  @Test
  func testFnFirstSeenOnNonModifierEventPassesThrough() {
    var classifier = GlobeGestureClassifier()

    classifier.receive(.fnAppearedOnNonModifierEvent)

    #expect(classifier.state == .fnPassThrough)
    #expect(classifier.receive(.globeUp(timestamp: 20_000_000)) == nil)
  }

  @Test
  func testDuplicateGlobeDownPassesThroughUntilGlobeUp() {
    var classifier = GlobeGestureClassifier()
    classifier.receive(
      .globeDown(
        timestamp: 0,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )

    classifier.receive(
      .globeDown(
        timestamp: 10_000_000,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )

    #expect(classifier.state == .fnPassThrough)
    #expect(classifier.receive(.globeUp(timestamp: 20_000_000)) == nil)
    #expect(classifier.state == .idle)
  }

  @Test
  func testOtherInputWhileIdleDoesNothingAndNextTapWorks() {
    var classifier = GlobeGestureClassifier()

    classifier.receive(.otherInput)
    #expect(classifier.state == .idle)

    classifier.receive(
      .globeDown(
        timestamp: 10,
        thresholdMilliseconds: 50,
        otherInputHeld: false
      )
    )
    #expect(
      classifier.receive(.globeUp(timestamp: 49_000_010))
        == GlobeTap(keyUpTimestamp: 49_000_010, thresholdMilliseconds: 50)
    )
  }

  @Test
  func testEarlierKeyUpAndZeroThresholdFailOpen() {
    var classifier = GlobeGestureClassifier()
    classifier.receive(
      .globeDown(
        timestamp: 100,
        thresholdMilliseconds: 300,
        otherInputHeld: false
      )
    )
    #expect(classifier.receive(.globeUp(timestamp: 99)) == nil)

    classifier.receive(
      .globeDown(
        timestamp: 100,
        thresholdMilliseconds: 0,
        otherInputHeld: false
      )
    )
    #expect(classifier.receive(.globeUp(timestamp: 100)) == nil)
  }

  @Test
  func testRapidTapsEachProduceOneTap() {
    var classifier = GlobeGestureClassifier()
    var taps: [GlobeTap] = []

    for start in [UInt64(0), 50_000_000, 100_000_000] {
      classifier.receive(
        .globeDown(
          timestamp: start,
          thresholdMilliseconds: 150,
          otherInputHeld: false
        )
      )
      if let tap = classifier.receive(
        .globeUp(timestamp: start + 20_000_000)
      ) {
        taps.append(tap)
      }
    }

    #expect(
      taps.map(\.keyUpTimestamp) == [
        20_000_000,
        70_000_000,
        120_000_000,
      ])
  }

  @Test
  func testZeroDurationPressIsTap() {
    var classifier = GlobeGestureClassifier()
    classifier.receive(
      .globeDown(
        timestamp: 100,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )

    #expect(
      classifier.receive(.globeUp(timestamp: 100))
        == GlobeTap(keyUpTimestamp: 100, thresholdMilliseconds: 150)
    )
  }

  @Test
  func testFnOnNonModifierEventCancelsCandidate() {
    var classifier = GlobeGestureClassifier()
    classifier.receive(
      .globeDown(
        timestamp: 0,
        thresholdMilliseconds: 150,
        otherInputHeld: false
      )
    )

    classifier.receive(.fnAppearedOnNonModifierEvent)

    #expect(classifier.state == .fnPassThrough)
    #expect(classifier.receive(.globeUp(timestamp: 20_000_000)) == nil)
    #expect(classifier.state == .idle)
  }

  @Test
  func testPassThroughIgnoresOtherInputAndEndsOnContinuityLoss() {
    var classifier = GlobeGestureClassifier()
    classifier.receive(
      .globeDown(
        timestamp: 0,
        thresholdMilliseconds: 150,
        otherInputHeld: true
      )
    )

    classifier.receive(.otherInput)
    #expect(classifier.state == .fnPassThrough)

    classifier.receive(.continuityLost)
    #expect(classifier.state == .idle)
  }

  @Test
  func testGlobeUpWhileIdleIsIgnored() {
    var classifier = GlobeGestureClassifier()

    #expect(classifier.receive(.globeUp(timestamp: 20_000_000)) == nil)
    #expect(classifier.state == .idle)
  }

  @Test
  func testTapAtEndOfClockRangeDoesNotOverflow() {
    var classifier = GlobeGestureClassifier()
    classifier.receive(
      .globeDown(
        timestamp: 18_446_744_073_609_551_615,
        thresholdMilliseconds: 300,
        otherInputHeld: false
      )
    )

    #expect(
      classifier.receive(.globeUp(timestamp: 18_446_744_073_709_551_615))
        == GlobeTap(
          keyUpTimestamp: 18_446_744_073_709_551_615,
          thresholdMilliseconds: 300
        )
    )
  }

  /// Drives random event sequences against the SPEC section 5 contract,
  /// tracked from the inputs alone rather than the classifier's own state.
  @Test
  func fuzzRandomEventSequencesHonorGestureContract() throws {
    try fuzz(iterations: 2_000) { rng, seed in
      var classifier = GlobeGestureClassifier()
      var clock = UInt64.random(in: 0...(1 << 62), using: &rng)
      // The press since the last Globe down, and whether it is still clean.
      var press: (start: UInt64, threshold: Int, clean: Bool)?
      // Fn seen outside a press keeps the gesture passing through.
      var passThrough = false

      for _ in 0..<64 {
        let input: GlobeGestureClassifier.Input
        switch rng.next() % 6 {
        case 0, 1:
          clock &+= UInt64.random(in: 0...50_000_000, using: &rng)
          let threshold =
            rng.oneIn(8)
            ? [0, -1, Int.min, Int.max, Int.random(in: .min ... .max, using: &rng)]
              .randomElement(using: &rng)!
            : Int.random(in: 50...300, using: &rng)
          input = .globeDown(
            timestamp: clock,
            thresholdMilliseconds: threshold,
            otherInputHeld: rng.oneIn(4)
          )
        case 2, 3:
          if rng.oneIn(16) {
            clock = rng.next()
          } else if let press, press.threshold >= 0, rng.oneIn(2) {
            // Land exactly on, or one nanosecond either side of, the threshold.
            let (boundary, overflow) = UInt64(press.threshold)
              .multipliedReportingOverflow(by: 1_000_000)
            if !overflow {
              let jitter = [-1, 0, 1].randomElement(using: &rng)!
              clock = press.start &+ boundary &+ UInt64(bitPattern: Int64(jitter))
            }
          } else {
            clock &+= UInt64.random(in: 0...400_000_000, using: &rng)
          }
          input = .globeUp(timestamp: clock)
        case 4:
          input = rng.oneIn(2) ? .otherInput : .fnAppearedOnNonModifierEvent
        default:
          input = rng.oneIn(8) ? .continuityLost : .otherInput
        }

        let tap = classifier.receive(input)

        switch input {
        case .globeDown(let timestamp, let threshold, let held):
          try #require(tap == nil, seed)
          press = (
            timestamp,
            threshold,
            press == nil && !passThrough && !held
          )
        case .globeUp(let timestamp):
          var expected: GlobeTap?
          if let press, press.clean, press.threshold >= 0,
            timestamp >= press.start
          {
            let (limit, overflow) = UInt64(press.threshold)
              .multipliedReportingOverflow(by: 1_000_000)
            if overflow || timestamp - press.start < limit {
              expected = GlobeTap(
                keyUpTimestamp: timestamp,
                thresholdMilliseconds: press.threshold
              )
            }
          }
          try #require(tap == expected, seed)
          try #require(classifier.state == .idle, seed)
          press = nil
          passThrough = false
        case .otherInput:
          try #require(tap == nil, seed)
          press?.clean = false
        case .fnAppearedOnNonModifierEvent:
          try #require(tap == nil, seed)
          press?.clean = false
          passThrough = true
        case .continuityLost:
          try #require(tap == nil, seed)
          try #require(classifier.state == .idle, seed)
          press = nil
          passThrough = false
        }
      }
    }
  }
}

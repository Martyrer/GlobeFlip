import Testing

@testable import GlobeFlipCore

@Suite("Input Source displacement")
struct InputSourceDisplacementDetectorTests {
  @Test("Detects one displacement inside watch window")
  func displacement() {
    var detector = InputSourceDisplacementDetector()
    detector.watch(targetID: "b", confirmedAt: 1_000)

    let stable = detector.detect(activeID: "b", at: 2_000)
    let displaced = detector.detect(activeID: "a", at: 3_000)
    let repeated = detector.detect(activeID: "a", at: 4_000)

    #expect(!stable)
    #expect(displaced)
    #expect(!repeated)
  }

  @Test("Nothing is detected before any watch")
  func unwatched() {
    var detector = InputSourceDisplacementDetector()
    let detected = detector.detect(activeID: "a", at: 0)
    #expect(!detected)
  }

  @Test("New intent and expiry fail open")
  func cancellation() {
    var detector = InputSourceDisplacementDetector()
    detector.watch(targetID: "b", confirmedAt: 1_000)
    detector.cancel()
    let cancelled = detector.detect(activeID: "a", at: 2_000)
    #expect(!cancelled)

    detector.watch(targetID: "b", confirmedAt: 3_000)
    let expired = detector.detect(activeID: "a", at: 1_000_003_001)
    let afterExpiry = detector.detect(activeID: "a", at: 4_000)
    #expect(!expired)
    #expect(!afterExpiry)
  }

  @Test("Application switch is not a source conflict and ends the watch")
  func applicationSwitch() {
    var detector = InputSourceDisplacementDetector()
    detector.watch(targetID: "b", contextID: 1, confirmedAt: 1_000)

    let otherApp = detector.detect(activeID: "a", contextID: 2, at: 2_000)
    let back = detector.detect(activeID: "a", contextID: 1, at: 3_000)

    #expect(!otherApp)
    #expect(!back)
  }

  @Test("A later watch replaces the earlier target")
  func rewatch() {
    var detector = InputSourceDisplacementDetector()
    detector.watch(targetID: "b", confirmedAt: 1_000)
    detector.watch(targetID: "a", confirmedAt: 2_000)

    let onNewTarget = detector.detect(activeID: "a", at: 3_000)
    let displaced = detector.detect(activeID: "b", at: 4_000)

    #expect(!onNewTarget)
    #expect(displaced)
  }

  @Test("Missing active source keeps watch and deadline is inclusive")
  func missingSourceAndBoundary() {
    var detector = InputSourceDisplacementDetector()
    detector.watch(targetID: "b", confirmedAt: 1_000)

    let missing = detector.detect(activeID: nil, at: 1_001)
    let boundary = detector.detect(activeID: "a", at: 1_000_001_000)
    #expect(!missing)
    #expect(boundary)
  }

  /// Random watch, cancel, and detect calls against the displacement contract:
  /// one report per watch, only for a different source in the same context
  /// inside the window, and a mismatch or expiry ends the watch.
  @Test("Fuzz: random call sequences honor the watch contract")
  func fuzzCallSequences() throws {
    let ids: [String?] = [nil, "a", "b", "c"]
    let contexts: [Int32?] = [nil, 1, 2]
    try fuzz(iterations: 2_000) { rng, seed in
      var detector = InputSourceDisplacementDetector()
      var clock = UInt64.random(in: 0...(1 << 62), using: &rng)
      var watch: (target: String, context: Int32?, deadline: UInt64)?

      for _ in 0..<64 {
        clock += UInt64.random(in: 0...400_000_000, using: &rng)
        switch rng.next() % 8 {
        case 0:
          let target = ["a", "b", "c"].randomElement(using: &rng)!
          let context = contexts.randomElement(using: &rng)!
          detector.watch(targetID: target, contextID: context, confirmedAt: clock)
          watch = (target, context, clock + 1_000_000_000)
        case 1:
          detector.cancel()
          watch = nil
        default:
          let active = ids.randomElement(using: &rng)!
          let context =
            rng.oneIn(4) ? contexts.randomElement(using: &rng)! : watch?.context
          let detected = detector.detect(
            activeID: active,
            contextID: context,
            at: clock
          )
          guard let current = watch else {
            try #require(!detected, seed)
            continue
          }
          if clock > current.deadline || context != current.context {
            try #require(!detected, seed)
            watch = nil
          } else if let active, active != current.target {
            try #require(detected, seed)
            watch = nil
          } else {
            try #require(!detected, seed)
          }
        }
      }
    }
  }
}

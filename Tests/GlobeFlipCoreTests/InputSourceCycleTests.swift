import Testing

@testable import GlobeFlipCore

@Suite
struct InputSourceCycleTests {
  @Test
  func firstDiscoveryUsesSnapshotOrder() {
    #expect(
      InputSourceCycle.reconciledOrder(
        persistedOrder: [],
        discoveredIDs: ["a", "b", "c"]
      ) == ["a", "b", "c"]
    )
  }

  @Test
  func refreshPreservesMissingIDsAndAppendsNewIDs() {
    #expect(
      InputSourceCycle.reconciledOrder(
        persistedOrder: ["b", "missing", "a"],
        discoveredIDs: ["a", "b", "new"]
      ) == ["b", "missing", "a", "new"]
    )
  }

  @Test
  func effectiveOrderContainsOnlyAvailableSources() {
    #expect(
      InputSourceCycle.effectiveOrder(
        persistedOrder: ["b", "missing", "a"],
        discoveredIDs: ["a", "b", "new"]
      ) == ["b", "a", "new"]
    )
  }

  @Test
  func nextSourceWraps() {
    #expect(
      InputSourceCycle.nextID(
        effectiveOrder: ["a", "b", "c"],
        activeID: "c"
      ) == "a"
    )
  }

  @Test
  func activeSourceOutsideCycleStartsAtFirstSource() {
    #expect(
      InputSourceCycle.nextID(
        effectiveOrder: ["a", "b"],
        activeID: "outside"
      ) == "a"
    )
  }

  @Test
  func missingActiveSourceStartsAtFirstSource() {
    #expect(
      InputSourceCycle.nextID(
        effectiveOrder: ["a", "b"],
        activeID: nil
      ) == "a"
    )
  }

  @Test
  func emptyAndDuplicateIDsAreRemoved() {
    #expect(
      InputSourceCycle.reconciledOrder(
        persistedOrder: ["", "b", "b", "a"],
        discoveredIDs: ["a", "", "c", "c"]
      ) == ["b", "a", "c"]
    )
  }

  @Test
  func fewerThanTwoSourcesHasNoTarget() {
    #expect(
      InputSourceCycle.nextID(effectiveOrder: ["a"], activeID: "a") == nil
    )
  }

  @Test
  func nextSourceAdvancesFromMiddle() {
    #expect(
      InputSourceCycle.nextID(
        effectiveOrder: ["a", "b", "c"],
        activeID: "b"
      ) == "c"
    )
  }

  @Test
  func emptyCycleHasNoTarget() {
    #expect(InputSourceCycle.nextID(effectiveOrder: [], activeID: nil) == nil)
  }

  @Test
  func fuzzReconciliationAndCycleInvariants() throws {
    let alphabet = ["", "a", "b", "c", "d", "e", "f"]
    try fuzz(iterations: 2_000) { rng, seed in
      func randomIDs() -> [String] {
        (0..<Int.random(in: 0...8, using: &rng)).map { _ in
          alphabet.randomElement(using: &rng)!
        }
      }
      let persisted = randomIDs()
      let discovered = randomIDs()
      let reconciled = InputSourceCycle.reconciledOrder(
        persistedOrder: persisted,
        discoveredIDs: discovered
      )
      let effective = InputSourceCycle.effectiveOrder(
        persistedOrder: persisted,
        discoveredIDs: discovered
      )
      let eligible = Set(discovered).subtracting([""])

      // Reconciled order: unique, non-empty, persisted order first, every ID kept.
      try #require(Set(reconciled).count == reconciled.count, seed)
      try #require(!reconciled.contains(""), seed)
      try #require(
        Set(reconciled) == Set(persisted + discovered).subtracting([""]),
        seed
      )
      let persistedPrefix = reconciled.prefix { persisted.contains($0) }
      try #require(Set(persistedPrefix) == Set(persisted).subtracting([""]), seed)
      try #require(
        InputSourceCycle.reconciledOrder(
          persistedOrder: reconciled,
          discoveredIDs: discovered
        ) == reconciled,
        seed
      )

      // Effective cycle: exactly the eligible IDs, in reconciled order.
      try #require(Set(effective) == eligible, seed)
      try #require(effective.count == eligible.count, seed)
      try #require(effective == reconciled.filter(eligible.contains), seed)

      // Once every ID is persisted, snapshot order no longer moves the cycle.
      try #require(
        InputSourceCycle.effectiveOrder(
          persistedOrder: reconciled,
          discoveredIDs: discovered.shuffled(using: &rng)
        ) == effective,
        seed
      )

      // A user reorder is the new cycle order verbatim.
      let reordered = reconciled.shuffled(using: &rng)
      try #require(
        InputSourceCycle.effectiveOrder(
          persistedOrder: reordered,
          discoveredIDs: discovered
        ) == reordered.filter(eligible.contains),
        seed
      )

      // Next target: always in the cycle, never the active source, and
      // repeated taps visit every source once before returning.
      let active = rng.oneIn(8) ? nil : alphabet.randomElement(using: &rng)
      let next = InputSourceCycle.nextID(
        effectiveOrder: effective,
        activeID: active
      )
      guard effective.count >= 2 else {
        try #require(next == nil, seed)
        return
      }
      let target = try #require(next, seed)
      try #require(effective.contains(target), seed)
      try #require(target != active, seed)
      if let active, !effective.contains(active) {
        try #require(target == effective.first, seed)
      }

      var visited = [target]
      for _ in 1..<effective.count {
        let step = try #require(
          InputSourceCycle.nextID(
            effectiveOrder: effective,
            activeID: visited.last
          ),
          seed
        )
        visited.append(step)
      }
      try #require(Set(visited) == eligible, seed)
      try #require(
        InputSourceCycle.nextID(effectiveOrder: effective, activeID: visited.last)
          == target,
        seed
      )
    }
  }
}

import Foundation
import Testing

@testable import GlobeFlipCore

@Suite
struct PreferencesStoreTests {
  private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }

  @Test
  @MainActor
  func testInvalidStoredValuesUseSafeValues() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(999, forKey: "tapThresholdMilliseconds")
    defaults.set("unknown", forKey: "appearance")
    defaults.set(
      ["source.one", "", "source.one", "source.two"],
      forKey: "sourceOrder"
    )

    let preferences = PreferencesStore(defaults: defaults)

    #expect(preferences.tapThresholdMilliseconds == 300)
    #expect(preferences.appearance == .system)
    #expect(preferences.sourceOrder == ["source.one", "source.two"])
  }

  @Test
  @MainActor
  func testWrongTypedStoredValuesUseDefaults() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("200", forKey: "tapThresholdMilliseconds")
    defaults.set("source.one", forKey: "sourceOrder")
    defaults.set(2, forKey: "appearance")
    defaults.set("3", forKey: "hapticPulseCount")

    let preferences = PreferencesStore(defaults: defaults)

    #expect(preferences.tapThresholdMilliseconds == 150)
    #expect(preferences.sourceOrder == [])
    #expect(preferences.appearance == .system)
    #expect(preferences.hapticPulseCount == 1)
  }

  @Test
  @MainActor
  func testStoredValuesBelowRangeAndMixedSourceIDsAreSanitized() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(-5, forKey: "tapThresholdMilliseconds")
    defaults.set(0, forKey: "hapticPulseCount")
    defaults.set([1, "source.one", true, "source.two"], forKey: "sourceOrder")

    let preferences = PreferencesStore(defaults: defaults)

    #expect(preferences.tapThresholdMilliseconds == 50)
    #expect(preferences.hapticPulseCount == 1)
    #expect(preferences.sourceOrder == ["source.one", "source.two"])
  }

  @Test
  @MainActor
  func testValidStoredValuesAreRestored() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(50, forKey: "tapThresholdMilliseconds")
    defaults.set("dark", forKey: "appearance")
    defaults.set(2, forKey: "hapticPulseCount")
    defaults.set(true, forKey: "hapticEnabled")
    defaults.set(true, forKey: "switchingPaused")

    let preferences = PreferencesStore(defaults: defaults)

    #expect(preferences.tapThresholdMilliseconds == 50)
    #expect(preferences.appearance == .dark)
    #expect(preferences.hapticPulseCount == 2)
    #expect(preferences.hapticEnabled)
    #expect(preferences.switchingPaused)
    #expect(!preferences.onboardingCompleted)
    #expect(!preferences.systemGlobeActionConfirmed)
  }

  @Test
  @MainActor
  func testLegacyOnboardingImpliesGlobeConfirmation() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "onboardingCompleted")

    let preferences = PreferencesStore(defaults: defaults)

    #expect(preferences.onboardingCompleted)
    #expect(preferences.systemGlobeActionConfirmed)
    #expect(defaults.object(forKey: "systemGlobeActionConfirmed") as? Bool == true)
  }

  @Test
  @MainActor
  func testExplicitGlobeConfirmationOverridesLegacyOnboarding() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "onboardingCompleted")
    defaults.set(false, forKey: "systemGlobeActionConfirmed")

    #expect(!PreferencesStore(defaults: defaults).systemGlobeActionConfirmed)
  }

  @Test
  @MainActor
  func testSystemGlobeConfirmationIsPersisted() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = PreferencesStore(defaults: defaults)

    preferences.systemGlobeActionConfirmed = true

    let restored = PreferencesStore(defaults: defaults)
    #expect(restored.systemGlobeActionConfirmed)
  }

  @Test
  @MainActor
  func testThresholdAssignmentIsClampedAndPersisted() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = PreferencesStore(defaults: defaults)

    preferences.tapThresholdMilliseconds = 20
    #expect(preferences.tapThresholdMilliseconds == 50)
    #expect(defaults.integer(forKey: "tapThresholdMilliseconds") == 50)

    preferences.tapThresholdMilliseconds = 301
    #expect(preferences.tapThresholdMilliseconds == 300)
    #expect(defaults.integer(forKey: "tapThresholdMilliseconds") == 300)

    preferences.tapThresholdMilliseconds = 300
    #expect(preferences.tapThresholdMilliseconds == 300)
    preferences.tapThresholdMilliseconds = 50
    #expect(preferences.tapThresholdMilliseconds == 50)
    preferences.tapThresholdMilliseconds = 170
    #expect(defaults.integer(forKey: "tapThresholdMilliseconds") == 170)
  }

  @Test
  @MainActor
  func testSourceOrderAssignmentIsValidatedAndPersisted() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = PreferencesStore(defaults: defaults)

    preferences.sourceOrder = ["source.one", "", "source.one", "source.two"]

    #expect(preferences.sourceOrder == ["source.one", "source.two"])
    #expect(
      defaults.stringArray(forKey: "sourceOrder")
        == ["source.one", "source.two"]
    )
  }

  @Test
  @MainActor
  func testHapticPulseCountIsValidatedAndPersisted() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = PreferencesStore(defaults: defaults)

    #expect(preferences.hapticPulseCount == 1)
    preferences.hapticPulseCount = 3
    #expect(PreferencesStore(defaults: defaults).hapticPulseCount == 3)
    preferences.hapticPulseCount = 9
    #expect(preferences.hapticPulseCount == 3)
    preferences.hapticPulseCount = 0
    #expect(preferences.hapticPulseCount == 1)
    #expect(defaults.integer(forKey: "hapticPulseCount") == 1)

    defaults.removeObject(forKey: "hapticPulseCount")
    defaults.set("long", forKey: "hapticDuration")
    let migrated = PreferencesStore(defaults: defaults)
    #expect(migrated.hapticPulseCount == 3)
    #expect(defaults.integer(forKey: "hapticPulseCount") == 3)
    #expect(defaults.object(forKey: "hapticDuration") == nil)
  }

  @Test
  @MainActor
  func testLegacyHapticDurationMigration() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    for (legacy, expected) in [("short", 1), ("medium", 2), ("bogus", 1)] {
      defaults.removeObject(forKey: "hapticPulseCount")
      defaults.set(legacy, forKey: "hapticDuration")
      #expect(PreferencesStore(defaults: defaults).hapticPulseCount == expected)
      #expect(defaults.object(forKey: "hapticDuration") == nil)
    }

    // An explicit pulse count wins over the legacy duration.
    defaults.set(1, forKey: "hapticPulseCount")
    defaults.set("long", forKey: "hapticDuration")
    #expect(PreferencesStore(defaults: defaults).hapticPulseCount == 1)
    #expect(defaults.object(forKey: "hapticDuration") == nil)
  }

  @Test
  @MainActor
  func testResetClearsOnlyAppPreferences() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("keep", forKey: "unrelated")
    let preferences = PreferencesStore(defaults: defaults)
    preferences.hapticEnabled = true
    preferences.hapticPulseCount = 3
    preferences.systemGlobeActionConfirmed = true
    preferences.appearance = .dark
    preferences.sourceOrder = ["source.one"]
    preferences.tapThresholdMilliseconds = 200
    preferences.switchingPaused = true
    preferences.onboardingCompleted = true

    preferences.reset()

    for key in [
      "hapticEnabled", "hapticPulseCount", "systemGlobeActionConfirmed",
      "appearance", "sourceOrder", "tapThresholdMilliseconds",
      "switchingPaused", "onboardingCompleted",
    ] {
      #expect(defaults.object(forKey: key) == nil, "\(key)")
    }
    #expect(defaults.string(forKey: "unrelated") == "keep")
    #expect(!preferences.hapticEnabled)
    #expect(preferences.hapticPulseCount == 1)
    #expect(!preferences.systemGlobeActionConfirmed)
    #expect(preferences.appearance == .system)
    #expect(preferences.sourceOrder == [])
    #expect(preferences.tapThresholdMilliseconds == 150)
    #expect(!preferences.switchingPaused)
    #expect(!preferences.onboardingCompleted)

    // Changes after a reset persist again.
    preferences.appearance = .light
    #expect(defaults.string(forKey: "appearance") == "light")
  }

  @Test
  @MainActor
  func testStatisticsUseCalendarPeriodsAndPersist() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let currentDate = date("2026-08-01")
    let store = SwitchStatisticsStore(
      defaults: defaults,
      calendar: calendar,
      currentDate: currentDate
    )

    store.recordSuccessfulSwitch(
      latencyMilliseconds: 100,
      at: date("2026-08-01")
    )
    store.recordSuccessfulSwitch(
      latencyMilliseconds: 200,
      at: date("2026-08-01")
    )
    store.recordSuccessfulSwitch(
      latencyMilliseconds: 400,
      at: date("2026-07-31")
    )
    store.recordSuccessfulSwitch(
      latencyMilliseconds: 1_000,
      at: date("2026-01-01")
    )
    store.recordSuccessfulSwitch(
      latencyMilliseconds: 50,
      at: date("2025-12-31")
    )
    store.refresh(at: currentDate)

    #expect(store.snapshot.todayCount == 2)
    #expect(store.snapshot.monthCount == 2)
    #expect(store.snapshot.yearCount == 4)
    #expect(store.snapshot.totalCount == 5)
    #expect(store.snapshot.todaySavedMilliseconds == 1_700)
    #expect(store.snapshot.monthSavedMilliseconds == 1_700)
    #expect(store.snapshot.yearSavedMilliseconds == 2_300)
    #expect(store.snapshot.totalSavedMilliseconds == 3_250)
    #expect(store.snapshot.activeDays == 4)
    #expect(store.snapshot.bestDayCount == 2)

    store.flush()
    let restored = SwitchStatisticsStore(
      defaults: defaults,
      calendar: calendar,
      currentDate: currentDate
    )
    #expect(restored.snapshot == store.snapshot)
  }

  @Test
  @MainActor
  func testStatisticsResetDoesNotResetPreferences() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = PreferencesStore(defaults: defaults)
    preferences.hapticEnabled = true
    let store = SwitchStatisticsStore(defaults: defaults)
    store.recordSuccessfulSwitch(latencyMilliseconds: 100)
    store.flush()
    store.refresh()
    #expect(store.snapshot.totalCount == 1)

    store.reset()

    #expect(store.snapshot.totalCount == 0)
    #expect(SwitchStatisticsStore(defaults: defaults).snapshot.totalCount == 0)
    #expect(PreferencesStore(defaults: defaults).hapticEnabled)
  }

  @Test
  @MainActor
  func testUnknownOrSlowLatencyCountsSwitchWithoutSavedTime() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SwitchStatisticsStore(defaults: defaults)

    for latency in [nil, Double.nan, .infinity, -.infinity, 1_000, 5_000] {
      store.recordSuccessfulSwitch(latencyMilliseconds: latency)
    }
    store.recordSuccessfulSwitch(latencyMilliseconds: 0)
    store.refresh()

    #expect(store.snapshot.totalCount == 7)
    #expect(store.snapshot.totalSavedMilliseconds == 1_000)
  }

  @Test
  @MainActor
  func testStatisticsRefreshAcrossCalendarBoundary() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let store = SwitchStatisticsStore(
      defaults: defaults,
      calendar: calendar,
      currentDate: date("2026-07-31")
    )
    store.recordSuccessfulSwitch(
      latencyMilliseconds: 100,
      at: date("2026-07-31")
    )
    store.refresh(at: date("2026-07-31"))
    #expect(store.snapshot.todayCount == 1)
    #expect(store.snapshot.monthCount == 1)

    store.refresh(at: date("2026-08-01"))
    #expect(store.snapshot.todayCount == 0)
    #expect(store.snapshot.monthCount == 0)
    #expect(store.snapshot.yearCount == 1)
  }

  @Test
  @MainActor
  func testCorruptStatisticsFallBackToEmpty() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    for json in [
      #"{"2026-08-01":{"count":-1,"savedMilliseconds":0}}"#,
      #"{"2026-08-01":{"count":1000001,"savedMilliseconds":0}}"#,
      #"{"2026-08-01":{"count":9223372036854775807,"savedMilliseconds":0}}"#,
      #"{"2026-08-01":{"count":1,"savedMilliseconds":-1}}"#,
      #"{"2026-08-01":{"count":1,"savedMilliseconds":1000000001}}"#,
      #"{"2026-08-01":{"count":1}}"#,
      #"["2026-08-01"]"#,
      "not json",
    ] {
      defaults.set(Data(json.utf8), forKey: "switchStatisticsByDay")
      let store = SwitchStatisticsStore(
        defaults: defaults,
        currentDate: date("2026-08-01")
      )
      #expect(store.snapshot.totalCount == 0, "\(json)")
      #expect(store.snapshot.totalSavedMilliseconds == 0, "\(json)")
    }
  }

  @Test
  @MainActor
  func testStatisticsAtDailyLimitsAreAccepted() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let json =
      #"{"2026-08-01":{"count":1000000,"savedMilliseconds":1000000000}}"#
    defaults.set(Data(json.utf8), forKey: "switchStatisticsByDay")

    let store = SwitchStatisticsStore(
      defaults: defaults,
      currentDate: date("2026-08-01")
    )

    #expect(store.snapshot.totalCount == 1_000_000)
    #expect(store.snapshot.totalSavedMilliseconds == 1_000_000_000)
  }

  /// Writes random property-list values, or nothing, under every stored key
  /// and checks that loading never traps and always yields in-range values.
  @Test
  @MainActor
  func fuzzGarbageStoredValuesLoadWithinValidRanges() throws {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keys = [
      "sourceOrder", "tapThresholdMilliseconds", "appearance", "hapticEnabled",
      "hapticPulseCount", "hapticDuration", "systemGlobeActionConfirmed",
      "switchingPaused", "onboardingCompleted", "switchStatisticsByDay",
    ]

    try fuzz(iterations: 300) { rng, seed in
      for key in keys {
        if rng.oneIn(3) {
          defaults.removeObject(forKey: key)
        } else {
          defaults.set(randomPropertyListValue(&rng, depth: 0), forKey: key)
        }
      }
      if rng.oneIn(2) {
        defaults.set(
          randomStatisticsJSON(&rng),
          forKey: "switchStatisticsByDay"
        )
      }

      let preferences = PreferencesStore(defaults: defaults)
      try #require((50...300).contains(preferences.tapThresholdMilliseconds), seed)
      try #require((1...3).contains(preferences.hapticPulseCount), seed)
      try #require(!preferences.sourceOrder.contains(""), seed)
      try #require(
        Set(preferences.sourceOrder).count == preferences.sourceOrder.count,
        seed
      )
      try #require(defaults.object(forKey: "hapticDuration") == nil, seed)

      // Arbitrary assignments are clamped and the clamped value is persisted.
      preferences.tapThresholdMilliseconds = Int.random(
        in: .min ... .max,
        using: &rng
      )
      preferences.hapticPulseCount = Int.random(in: -5...8, using: &rng)
      try #require((50...300).contains(preferences.tapThresholdMilliseconds), seed)
      try #require((1...3).contains(preferences.hapticPulseCount), seed)
      try #require(
        defaults.integer(forKey: "tapThresholdMilliseconds")
          == preferences.tapThresholdMilliseconds,
        seed
      )
      try #require(
        defaults.integer(forKey: "hapticPulseCount")
          == preferences.hapticPulseCount,
        seed
      )

      let snapshot = SwitchStatisticsStore(defaults: defaults).snapshot
      try #require(snapshot.todayCount >= 0, seed)
      try #require(snapshot.todayCount <= snapshot.monthCount, seed)
      try #require(snapshot.monthCount <= snapshot.yearCount, seed)
      try #require(snapshot.yearCount <= snapshot.totalCount, seed)
      try #require(snapshot.bestDayCount <= snapshot.totalCount, seed)
      try #require(snapshot.activeDays >= 0, seed)
      for saved in [
        snapshot.todaySavedMilliseconds, snapshot.monthSavedMilliseconds,
        snapshot.yearSavedMilliseconds, snapshot.totalSavedMilliseconds,
      ] {
        try #require(saved.isFinite && saved >= 0, seed)
      }
    }
  }

  private func randomPropertyListValue(
    _ rng: inout SplitMix64,
    depth: Int
  ) -> Any {
    switch rng.next() % (depth < 2 ? 9 : 7) {
    case 0: return Int.random(in: .min ... .max, using: &rng)
    case 1: return Int.random(in: -10...400, using: &rng)
    case 2:
      return [Double.nan, .infinity, -1.5, 150.0, 150.5]
        .randomElement(using: &rng)!
    case 3: return Bool.random(using: &rng)
    case 4:
      return ["", "dark", "light", "system", "medium", "long", "150", "\u{0}"]
        .randomElement(using: &rng)!
    case 5:
      return Data(
        (0..<Int.random(in: 0...16, using: &rng)).map { _ in
          UInt8.random(in: 0...255, using: &rng)
        })
    case 6: return Date(timeIntervalSince1970: Double.random(in: -1e10...1e10, using: &rng))
    case 7:
      return (0..<Int.random(in: 0...5, using: &rng)).map { _ in
        randomPropertyListValue(&rng, depth: depth + 1)
      }
    default:
      return Dictionary(
        uniqueKeysWithValues: (0..<Int.random(in: 0...3, using: &rng)).map {
          ("k\($0)", randomPropertyListValue(&rng, depth: depth + 1))
        }
      )
    }
  }

  /// Well-formed statistics JSON whose day records may be out of range.
  private func randomStatisticsJSON(_ rng: inout SplitMix64) -> Data {
    var records: [String: Any] = [:]
    for _ in 0..<Int.random(in: 0...6, using: &rng) {
      let day = String(
        format: "%04d-%02d-%02d",
        Int.random(in: 2024...2027, using: &rng),
        Int.random(in: 1...12, using: &rng),
        Int.random(in: 1...28, using: &rng)
      )
      records[day] = [
        "count": rng.oneIn(4)
          ? Int.random(in: .min ... .max, using: &rng)
          : Int.random(in: 0...1_000_000, using: &rng),
        "savedMilliseconds": rng.oneIn(4)
          ? Double.random(in: -1e300...1e300, using: &rng)
          : Double.random(in: 0...1e9, using: &rng),
      ]
    }
    return try! JSONSerialization.data(withJSONObject: records)
  }

  private func date(_ day: String) -> Date {
    ISO8601DateFormatter().date(from: "\(day)T12:00:00Z")!
  }
}

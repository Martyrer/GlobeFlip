import Combine
import Foundation

public struct SwitchStatisticsSnapshot: Equatable, Sendable {
  public let todayCount: Int
  public let monthCount: Int
  public let yearCount: Int
  public let totalCount: Int
  public let todaySavedMilliseconds: Double
  public let monthSavedMilliseconds: Double
  public let yearSavedMilliseconds: Double
  public let totalSavedMilliseconds: Double
  public let activeDays: Int
  public let bestDayCount: Int
}

@MainActor
public final class SwitchStatisticsStore {
  public static let manualSwitchBaselineMilliseconds = 1_000.0

  private struct DailyRecord: Codable, Sendable {
    var count: Int
    var savedMilliseconds: Double
  }

  private static let storageKey = "switchStatisticsByDay"
  private static let maximumStoredDays = 36_600
  private static let maximumDailyCount = 1_000_000
  private static let maximumDailySavedMilliseconds =
    Double(maximumDailyCount) * manualSwitchBaselineMilliseconds

  private let defaults: UserDefaults
  private let calendar: Calendar
  private var records: [String: DailyRecord]
  private var persistenceTask: Task<Void, Never>?

  public private(set) var snapshot: SwitchStatisticsSnapshot

  public init(
    defaults: UserDefaults = .standard,
    calendar: Calendar = .current,
    currentDate: Date = Date()
  ) {
    self.defaults = defaults
    self.calendar = calendar
    records = Self.loadRecords(from: defaults)
    snapshot = Self.makeSnapshot(
      records: records,
      at: currentDate,
      calendar: calendar
    )
  }

  public func recordSuccessfulSwitch(
    latencyMilliseconds: Double?,
    at date: Date = Date()
  ) {
    let key = Self.dayKey(for: date, calendar: calendar)
    let latency =
      latencyMilliseconds?.isFinite == true ? latencyMilliseconds : nil
    let saved =
      latency.map {
        max(0, Self.manualSwitchBaselineMilliseconds - $0)
      } ?? 0
    var record = records[key] ?? DailyRecord(count: 0, savedMilliseconds: 0)
    record.count = min(record.count + 1, Self.maximumDailyCount)
    record.savedMilliseconds = min(
      record.savedMilliseconds + saved,
      Self.maximumDailySavedMilliseconds
    )
    records[key] = record
    schedulePersistence()
  }

  public func reset(at date: Date = Date()) {
    persistenceTask?.cancel()
    persistenceTask = nil
    records = [:]
    defaults.removeObject(forKey: Self.storageKey)
    refresh(at: date)
  }

  public func refresh(at date: Date = Date()) {
    snapshot = Self.makeSnapshot(records: records, at: date, calendar: calendar)
  }

  public func flush() {
    persistenceTask?.cancel()
    persistenceTask = nil
    guard let data = try? JSONEncoder().encode(records) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }

  private func schedulePersistence() {
    persistenceTask?.cancel()
    let records = records
    persistenceTask = Task { [defaults] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      let data = await Task.detached {
        try? JSONEncoder().encode(records)
      }.value
      guard !Task.isCancelled, let data else { return }
      defaults.set(data, forKey: Self.storageKey)
    }
  }

  private static func loadRecords(
    from defaults: UserDefaults
  ) -> [String: DailyRecord] {
    guard let data = defaults.data(forKey: storageKey) else { return [:] }
    guard
      let records = try? JSONDecoder().decode(
        [String: DailyRecord].self,
        from: data
      ),
      records.count <= maximumStoredDays,
      records.values.allSatisfy({
        $0.count >= 0
          && $0.count <= maximumDailyCount
          && $0.savedMilliseconds.isFinite
          && $0.savedMilliseconds >= 0
          && $0.savedMilliseconds <= maximumDailySavedMilliseconds
      })
    else {
      return [:]
    }
    return records
  }

  private static func makeSnapshot(
    records: [String: DailyRecord],
    at date: Date,
    calendar: Calendar
  ) -> SwitchStatisticsSnapshot {
    let day = dayKey(for: date, calendar: calendar)
    let month = String(day.prefix(7))
    let year = String(day.prefix(4))
    let today = records[day]
    let monthRecords = records.filter { $0.key.hasPrefix(month) }.map(\.value)
    let yearRecords = records.filter { $0.key.hasPrefix(year) }.map(\.value)
    let allRecords = Array(records.values)

    return SwitchStatisticsSnapshot(
      todayCount: today?.count ?? 0,
      monthCount: count(monthRecords),
      yearCount: count(yearRecords),
      totalCount: count(allRecords),
      todaySavedMilliseconds: today?.savedMilliseconds ?? 0,
      monthSavedMilliseconds: savedMilliseconds(monthRecords),
      yearSavedMilliseconds: savedMilliseconds(yearRecords),
      totalSavedMilliseconds: savedMilliseconds(allRecords),
      activeDays: records.count,
      bestDayCount: allRecords.map(\.count).max() ?? 0
    )
  }

  private static func count(_ records: [DailyRecord]) -> Int {
    records.reduce(0) { total, record in
      let (sum, overflow) = total.addingReportingOverflow(record.count)
      return overflow ? Int.max : sum
    }
  }

  private static func savedMilliseconds(_ records: [DailyRecord]) -> Double {
    let total = records.reduce(0.0) { $0 + $1.savedMilliseconds }
    return total.isFinite ? total : Double.greatestFiniteMagnitude
  }

  private static func dayKey(for date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }
}

@MainActor
public final class PreferencesStore: ObservableObject {
  public static let defaultTapThresholdMilliseconds = 150
  public static let tapThresholdRange = TimingCalibration.allowedRange
  public static let defaultHapticPulseCount = 1
  public static let hapticPulseCountRange = 1...3

  private enum Key {
    static let sourceOrder = "sourceOrder"
    static let tapThresholdMilliseconds = "tapThresholdMilliseconds"
    static let appearance = "appearance"
    static let hapticEnabled = "hapticEnabled"
    static let hapticPulseCount = "hapticPulseCount"
    static let legacyHapticDuration = "hapticDuration"
    static let systemGlobeActionConfirmed = "systemGlobeActionConfirmed"
    static let switchingPaused = "switchingPaused"
    static let onboardingCompleted = "onboardingCompleted"

    static let all = [
      sourceOrder,
      tapThresholdMilliseconds,
      appearance,
      hapticEnabled,
      hapticPulseCount,
      legacyHapticDuration,
      systemGlobeActionConfirmed,
      switchingPaused,
      onboardingCompleted,
    ]
  }

  private let defaults: UserDefaults
  private var shouldPersist = true

  @Published public var sourceOrder: [String] {
    didSet {
      let validated = Self.validatedSourceOrder(sourceOrder)
      if sourceOrder != validated {
        sourceOrder = validated
      } else {
        persist(validated, forKey: Key.sourceOrder)
      }
    }
  }

  @Published public var tapThresholdMilliseconds: Int {
    didSet {
      let validated = Self.validatedThreshold(tapThresholdMilliseconds)
      if tapThresholdMilliseconds != validated {
        tapThresholdMilliseconds = validated
      } else {
        persist(validated, forKey: Key.tapThresholdMilliseconds)
      }
    }
  }

  @Published public var appearance: Appearance {
    didSet { persist(appearance.rawValue, forKey: Key.appearance) }
  }

  @Published public var hapticEnabled: Bool {
    didSet { persist(hapticEnabled, forKey: Key.hapticEnabled) }
  }

  @Published public var hapticPulseCount: Int {
    didSet {
      let validated = Self.validatedHapticPulseCount(hapticPulseCount)
      if hapticPulseCount != validated {
        hapticPulseCount = validated
      } else {
        persist(validated, forKey: Key.hapticPulseCount)
      }
    }
  }

  @Published public var systemGlobeActionConfirmed: Bool {
    didSet {
      persist(
        systemGlobeActionConfirmed,
        forKey: Key.systemGlobeActionConfirmed
      )
    }
  }

  @Published public var switchingPaused: Bool {
    didSet { persist(switchingPaused, forKey: Key.switchingPaused) }
  }

  @Published public var onboardingCompleted: Bool {
    didSet { persist(onboardingCompleted, forKey: Key.onboardingCompleted) }
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let completedOnboarding = defaults.bool(forKey: Key.onboardingCompleted)
    let storedGlobeConfirmation =
      defaults.object(forKey: Key.systemGlobeActionConfirmed) as? Bool
    let storedHapticPulseCount =
      defaults.object(forKey: Key.hapticPulseCount) as? Int
    let legacyHapticPulseCount: Int? =
      switch defaults.string(forKey: Key.legacyHapticDuration) {
      case "medium": 2
      case "long": 3
      default: nil
      }
    sourceOrder = Self.validatedSourceOrder(
      defaults.array(forKey: Key.sourceOrder) ?? []
    )
    tapThresholdMilliseconds = Self.validatedThreshold(
      defaults.object(forKey: Key.tapThresholdMilliseconds) as? Int
        ?? Self.defaultTapThresholdMilliseconds
    )
    appearance =
      Appearance(
        rawValue: defaults.string(forKey: Key.appearance) ?? ""
      ) ?? .system
    hapticEnabled = defaults.bool(forKey: Key.hapticEnabled)
    hapticPulseCount = Self.validatedHapticPulseCount(
      storedHapticPulseCount
        ?? legacyHapticPulseCount
        ?? Self.defaultHapticPulseCount
    )
    systemGlobeActionConfirmed =
      storedGlobeConfirmation ?? completedOnboarding
    switchingPaused = defaults.bool(forKey: Key.switchingPaused)
    onboardingCompleted = completedOnboarding

    if storedGlobeConfirmation == nil, completedOnboarding {
      defaults.set(true, forKey: Key.systemGlobeActionConfirmed)
    }
    if storedHapticPulseCount == nil, legacyHapticPulseCount != nil {
      defaults.set(hapticPulseCount, forKey: Key.hapticPulseCount)
    }
    defaults.removeObject(forKey: Key.legacyHapticDuration)
  }

  public func reset() {
    shouldPersist = false
    Key.all.forEach(defaults.removeObject(forKey:))
    sourceOrder = []
    tapThresholdMilliseconds = Self.defaultTapThresholdMilliseconds
    appearance = .system
    hapticEnabled = false
    hapticPulseCount = Self.defaultHapticPulseCount
    systemGlobeActionConfirmed = false
    switchingPaused = false
    onboardingCompleted = false
    shouldPersist = true
  }

  private func persist(_ value: Any, forKey key: String) {
    guard shouldPersist else { return }
    defaults.set(value, forKey: key)
  }

  private static func validatedThreshold(_ value: Int) -> Int {
    min(max(value, tapThresholdRange.lowerBound), tapThresholdRange.upperBound)
  }

  private static func validatedHapticPulseCount(_ value: Int) -> Int {
    min(
      max(value, hapticPulseCountRange.lowerBound),
      hapticPulseCountRange.upperBound
    )
  }

  private static func validatedSourceOrder(_ values: [Any]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      guard let id = value as? String, !id.isEmpty, seen.insert(id).inserted else {
        return nil
      }
      return id
    }
  }
}

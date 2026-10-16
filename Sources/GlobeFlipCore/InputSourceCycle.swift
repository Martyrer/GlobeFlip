public struct SwitchIntent: Equatable, Sendable {
  public static let confirmationWindowNanoseconds: UInt64 = 100_000_000

  public let sequenceNumber: UInt64
  public let keyUpTimestamp: UInt64

  public init(
    sequenceNumber: UInt64,
    keyUpTimestamp: UInt64
  ) {
    self.sequenceNumber = sequenceNumber
    self.keyUpTimestamp = keyUpTimestamp
  }

  public var confirmationDeadline: UInt64? {
    let (deadline, overflow) = keyUpTimestamp.addingReportingOverflow(
      Self.confirmationWindowNanoseconds
    )
    return overflow ? nil : deadline
  }

  public static func remainingNanoseconds(
    until deadline: UInt64,
    at timestamp: UInt64
  ) -> UInt64? {
    timestamp < deadline ? deadline - timestamp : nil
  }
}

public enum InputSourceCycle {
  public static func reconciledOrder(
    persistedOrder: [String],
    discoveredIDs: [String]
  ) -> [String] {
    let persistedOrder = unique(persistedOrder)
    let discoveredIDs = unique(discoveredIDs)
    let known = Set(persistedOrder)
    return persistedOrder + discoveredIDs.filter { !known.contains($0) }
  }

  public static func effectiveOrder(
    persistedOrder: [String],
    discoveredIDs: [String]
  ) -> [String] {
    let available = Set(discoveredIDs)
    return reconciledOrder(
      persistedOrder: persistedOrder,
      discoveredIDs: discoveredIDs
    ).filter(available.contains)
  }

  public static func nextID(
    effectiveOrder: [String],
    activeID: String?
  ) -> String? {
    guard effectiveOrder.count >= 2 else { return nil }
    guard let activeID,
      let activeIndex = effectiveOrder.firstIndex(of: activeID)
    else {
      return effectiveOrder.first
    }
    return effectiveOrder[(activeIndex + 1) % effectiveOrder.count]
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}

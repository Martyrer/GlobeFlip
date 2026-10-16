public struct InputSourceDisplacementDetector: Sendable {
  public static let watchWindowNanoseconds: UInt64 = 1_000_000_000

  private var targetID: String?
  private var contextID: Int32?
  private var deadline: UInt64 = 0

  public init() {}

  public mutating func watch(
    targetID: String,
    contextID: Int32? = nil,
    confirmedAt timestamp: UInt64
  ) {
    self.targetID = targetID
    self.contextID = contextID
    deadline = timestamp &+ Self.watchWindowNanoseconds
  }

  public mutating func cancel() {
    targetID = nil
    contextID = nil
    deadline = 0
  }

  public mutating func detect(
    activeID: String?,
    contextID: Int32? = nil,
    at timestamp: UInt64
  ) -> Bool {
    guard let targetID else { return false }
    guard timestamp <= deadline else {
      cancel()
      return false
    }
    guard contextID == self.contextID else {
      cancel()
      return false
    }
    guard let activeID, activeID != targetID else { return false }
    cancel()
    return true
  }
}

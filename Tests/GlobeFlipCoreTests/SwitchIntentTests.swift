import Testing

@testable import GlobeFlipCore

@Suite
struct SwitchIntentTests {
  @Test
  func deadlineIsKeyUpPlus100Milliseconds() {
    let intent = SwitchIntent(sequenceNumber: 1, keyUpTimestamp: 42)
    #expect(intent.confirmationDeadline == 100_000_042)
  }

  @Test
  func deadlineAtEndOfClockRangeAndOverflow() {
    let last = SwitchIntent(
      sequenceNumber: 1,
      keyUpTimestamp: 18_446_744_073_609_551_615
    )
    #expect(last.confirmationDeadline == 18_446_744_073_709_551_615)

    let overflowing = SwitchIntent(
      sequenceNumber: 2,
      keyUpTimestamp: 18_446_744_073_609_551_616
    )
    #expect(overflowing.confirmationDeadline == nil)
  }

  @Test
  func deadlineBoundaryAndLateWakeAreExpired() {
    #expect(
      SwitchIntent.remainingNanoseconds(until: 100, at: 99) == 1
    )
    #expect(
      SwitchIntent.remainingNanoseconds(until: 100, at: 100) == nil
    )
    #expect(
      SwitchIntent.remainingNanoseconds(until: 100, at: 101) == nil
    )
  }
}

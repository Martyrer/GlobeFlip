import Carbon
import CoreGraphics
import Foundation
import Testing

@testable import GlobeFlip
@testable import GlobeFlipCore

@Suite("Event tap disablement history")
struct EventTapDisablementHistoryTests {
  @Test("Second disablement inside the 30 s window is terminal")
  func repeatedWithinWindow() {
    var history = EventTapDisablementHistory()

    let results = [1_000, 1_000 + 30_000_000_000].map {
      history.recordIsRepeated(at: $0)
    }

    #expect(results == [false, true])
  }

  @Test("Disablement after the window re-enables and restarts the window")
  func windowExpires() {
    var history = EventTapDisablementHistory()

    let results = [0, 30_000_000_001, 60_000_000_001, 90_000_000_002].map {
      history.recordIsRepeated(at: $0)
    }

    #expect(results == [false, false, true, false])
  }
}

@Suite("Globe event monitor")
struct GlobeEventMonitorTests {
  @Test("Clean Globe tap below threshold emits one tap")
  func cleanTap() {
    let probe = MonitorProbe(threshold: 150)

    probe.globe(down: true, at: 1_000_000_000)
    probe.globe(down: false, at: 1_149_999_999)

    #expect(
      probe.taps
        == [GlobeTap(keyUpTimestamp: 1_149_999_999, thresholdMilliseconds: 150)]
    )
  }

  @Test("Release at the threshold is a hold")
  func holdAtThreshold() {
    let probe = MonitorProbe(threshold: 150)

    probe.globe(down: true, at: 1_000_000_000)
    probe.globe(down: false, at: 1_150_000_000)

    #expect(probe.taps == [])
  }

  @Test("Threshold is clamped and snapshotted at Globe down")
  func thresholdClampAndSnapshot() {
    let probe = MonitorProbe(threshold: 10)

    probe.globe(down: true, at: 0)
    probe.monitor.updateThreshold(1_000)
    probe.globe(down: false, at: 10_000_000)
    probe.globe(down: true, at: 20_000_000)
    probe.globe(down: false, at: 300_000_000)

    #expect(
      probe.taps
        == [
          GlobeTap(keyUpTimestamp: 10_000_000, thresholdMilliseconds: 50),
          GlobeTap(keyUpTimestamp: 300_000_000, thresholdMilliseconds: 300),
        ]
    )
  }

  @Test("Key held before Globe down prevents a tap")
  func keyHeldBeforeDown() {
    let probe = MonitorProbe()

    probe.key(0, down: true, at: 0)
    probe.globe(down: true, at: 1)
    probe.globe(down: false, at: 2)
    probe.key(0, down: false, at: 3)
    probe.globe(down: true, at: 4)
    probe.globe(down: false, at: 5)

    #expect(probe.taps.map(\.keyUpTimestamp) == [5])
  }

  @Test("Key pressed and released during the gesture cancels the tap")
  func keyJoinsGesture() {
    let probe = MonitorProbe()

    probe.globe(down: true, at: 0)
    probe.key(123, down: true, at: 1, fn: true)
    probe.key(123, down: false, at: 2, fn: true)
    probe.globe(down: false, at: 3)

    #expect(probe.taps == [])
  }

  @Test("Modifier held at Globe down, joining, or at Globe up cancels the tap")
  func modifiersCancel() {
    let probe = MonitorProbe()

    probe.globe(down: true, at: 0, extraFlags: .maskCommand)
    probe.globe(down: false, at: 1)

    probe.globe(down: true, at: 2)
    probe.send(.flagsChanged, keyCode: 56, flags: [.maskSecondaryFn, .maskShift], at: 3)
    probe.send(.flagsChanged, keyCode: 56, flags: .maskSecondaryFn, at: 4)
    probe.globe(down: false, at: 5)

    probe.globe(down: true, at: 6)
    probe.globe(down: false, at: 7, extraFlags: .maskAlternate)

    #expect(probe.taps == [])
  }

  @Test("System-defined event during the gesture cancels the tap")
  func systemDefinedCancels() {
    let probe = MonitorProbe()

    probe.globe(down: true, at: 0)
    probe.send(
      CGEventType(rawValue: 14)!,
      keyCode: 0,
      flags: .maskSecondaryFn,
      at: 1
    )
    probe.globe(down: false, at: 2)

    #expect(probe.taps == [])
  }

  @Test("Duplicate Globe down edge cancels the tap")
  func duplicateDownCancels() {
    let probe = MonitorProbe()

    probe.globe(down: true, at: 0)
    probe.globe(down: true, at: 1)
    probe.globe(down: false, at: 2)

    #expect(probe.taps == [])
  }

  @Test("Duplicate Globe down after lost continuity does not start a tap")
  func duplicateDownAfterLostContinuity() {
    let probe = MonitorProbe()

    probe.globe(down: true, at: 0)
    probe.key(63, down: true, at: 1, fn: true)
    probe.globe(down: true, at: 2)
    probe.globe(down: false, at: 3)

    #expect(probe.taps == [])
  }

  @Test("Fn first seen on a non-modifier event passes through")
  func fnOnNonModifierEvent() {
    let probe = MonitorProbe()

    probe.key(200, down: true, at: 0, fn: true)
    probe.globe(down: false, at: 1)
    probe.globe(down: true, at: 2)
    probe.key(200, down: false, at: 3, fn: false)
    probe.globe(down: false, at: 4)

    #expect(probe.taps == [])
  }

  @Test("Missing Globe up edge on a modifier event clears the gesture")
  func missingGlobeUpOnModifierEvent() {
    let probe = MonitorProbe()

    probe.globe(down: true, at: 0)
    // Fn release observed only on a Shift event: the Globe up edge is missing.
    probe.send(.flagsChanged, keyCode: 56, flags: .maskShift, at: 1)
    probe.send(.flagsChanged, keyCode: 56, flags: [], at: 2)
    probe.globe(down: true, at: 3)
    probe.globe(down: false, at: 4)

    #expect(probe.taps.map(\.keyUpTimestamp) == [4])
  }

  @Test("Key codes above the keyboard range do not join the gesture")
  func companionKeyCodesIgnored() {
    let probe = MonitorProbe()

    probe.globe(down: true, at: 0)
    probe.key(179, down: true, at: 1, fn: true)
    probe.key(179, down: false, at: 2, fn: true)
    probe.globe(down: false, at: 3)

    #expect(probe.taps.map(\.keyUpTimestamp) == [3])
  }

  @Test("Globe key-down event loses continuity")
  func globeKeyDownLosesContinuity() {
    let probe = MonitorProbe()

    probe.globe(down: true, at: 0)
    probe.key(63, down: true, at: 1, fn: true)
    probe.globe(down: false, at: 2)

    #expect(probe.taps == [])
  }

  @Test("Calibration reports clean presses and cancels joined ones")
  func calibrationEvents() {
    let probe = MonitorProbe()
    probe.globe(down: true, at: 0)
    probe.globe(down: false, at: 1_000_000)
    #expect(probe.calibrationEvents == [])

    probe.monitor.setCalibrationEnabled(true)
    probe.globe(down: true, at: 10_000_000)
    probe.globe(down: false, at: 410_000_000)
    probe.globe(down: true, at: 500_000_000)
    probe.key(0, down: true, at: 510_000_000, fn: true)
    probe.key(0, down: false, at: 520_000_000, fn: true)
    probe.globe(down: false, at: 530_000_000)
    // A key held before Globe down never starts a calibration press.
    probe.key(0, down: true, at: 600_000_000)
    probe.globe(down: true, at: 610_000_000)
    probe.globe(down: false, at: 620_000_000)
    probe.key(0, down: false, at: 630_000_000)

    #expect(
      probe.calibrationEvents
        == [
          .pressBegan(timestamp: 10_000_000),
          .pressEnded(durationMilliseconds: 400),
          .pressBegan(timestamp: 500_000_000),
          .cancelled,
        ]
    )
    // A 400 ms calibration press is a hold, not a tap.
    #expect(probe.taps.map(\.keyUpTimestamp) == [1_000_000])
  }

  @Test("Fuzzed event streams emit exactly the taps the gesture contract allows")
  func fuzzedEventStreams() {
    let iterations = AppFuzz.iterations(default: 200)
    var totalTaps = 0

    for iteration in 0..<iterations {
      let seed = AppFuzz.seed(forIteration: iteration)
      var random = SplitMix64(seed: seed)
      let probe = MonitorProbe(threshold: Int.random(in: 50...300, using: &random))
      var oracle = GestureOracle(threshold: probe.threshold)
      var expected: [GlobeTap] = []
      var timestamp = UInt64.random(in: 0...1_000_000_000, using: &random)

      for _ in 0..<80 {
        let events = randomEvents(oracle: oracle, timestamp: &timestamp, random: &random)
        for event in events {
          if case .threshold(let value) = event {
            probe.monitor.updateThreshold(value)
            oracle.threshold = min(max(value, 50), 300)
            continue
          }
          guard case .input(let type, let keyCode, let flags, let at) = event
          else { continue }
          probe.send(type, keyCode: keyCode, flags: flags, at: at)
          if let tap = oracle.receive(type: type, keyCode: keyCode, flags: flags, at: at) {
            expected.append(tap)
          }
        }
      }

      #expect(probe.taps == expected, "seed \(seed)")
      totalTaps += expected.count
      if probe.taps != expected { break }
    }

    // The generator must reach the tap path, or the oracle proves nothing.
    #expect(totalTaps >= iterations)
  }
}

private enum FuzzEvent {
  case input(CGEventType, keyCode: Int64, flags: CGEventFlags, at: UInt64)
  case threshold(Int)
}

private let fuzzModifiers: [(keyCode: Int64, flag: CGEventFlags)] = [
  (56, .maskShift), (59, .maskControl), (58, .maskAlternate),
  (55, .maskCommand), (114, .maskHelp),
]

private func randomEvents(
  oracle: GestureOracle,
  timestamp: inout UInt64,
  random: inout SplitMix64
) -> [FuzzEvent] {
  func advance(_ range: ClosedRange<UInt64>) -> UInt64 {
    if random.chance(0.03) {
      timestamp &-= UInt64.random(in: 0...50_000_000, using: &random)
    } else {
      timestamp &+= UInt64.random(in: range, using: &random)
    }
    return timestamp
  }
  let fnFlag: CGEventFlags = oracle.fnDown ? .maskSecondaryFn : []
  let heldFlags = random.chance(0.2)
    ? fuzzModifiers.randomElement(using: &random)!.flag : []

  switch Int.random(in: 0..<100, using: &random) {
  case 0..<35:
    // A clean gesture: release held input, then press and release Globe.
    var events: [FuzzEvent] = oracle.heldKeys.sorted().map {
      .input(.keyUp, keyCode: $0, flags: fnFlag, at: advance(0...5_000_000))
    }
    if oracle.fnDown {
      events.append(.input(.flagsChanged, keyCode: 63, flags: [], at: advance(0...5_000_000)))
    }
    events.append(
      .input(.flagsChanged, keyCode: 63, flags: .maskSecondaryFn, at: advance(1_000_000...50_000_000))
    )
    let limit = UInt64(oracle.threshold) * 1_000_000
    let hold = random.chance(0.1)
      ? limit &+ UInt64.random(in: 0...1, using: &random) &- 1
      : UInt64.random(in: 0...(limit * 2), using: &random)
    timestamp &+= hold
    events.append(.input(.flagsChanged, keyCode: 63, flags: [], at: timestamp))
    return events
  case 35..<50:
    let down = !oracle.fnDown || random.chance(0.15)
    return [
      .input(
        .flagsChanged,
        keyCode: 63,
        flags: (down ? CGEventFlags.maskSecondaryFn : []).union(heldFlags),
        at: advance(0...200_000_000)
      )
    ]
  case 50..<70:
    let keyCode =
      random.chance(0.1)
      ? Int64.random(in: 127...255, using: &random)
      : random.chance(0.05) ? 63 : Int64.random(in: 0...126, using: &random)
    let isDown = !oracle.heldKeys.contains(keyCode) || random.chance(0.2)
    let flags = random.chance(0.1) ? fnFlag.symmetricDifference(.maskSecondaryFn) : fnFlag
    return [
      .input(isDown ? .keyDown : .keyUp, keyCode: keyCode, flags: flags, at: advance(0...100_000_000))
    ]
  case 70..<82:
    let modifier = fuzzModifiers.randomElement(using: &random)!
    var flags = random.chance(0.5) ? fnFlag.union(modifier.flag) : fnFlag
    if random.chance(0.1) {
      flags.formSymmetricDifference(.maskSecondaryFn)
    }
    return [.input(.flagsChanged, keyCode: modifier.keyCode, flags: flags, at: advance(0...100_000_000))]
  case 82..<90:
    return [.input(CGEventType(rawValue: 14)!, keyCode: 0, flags: fnFlag, at: advance(0...100_000_000))]
  case 90..<95:
    return [.threshold(Int.random(in: -20...400, using: &random))]
  default:
    // Mouse events are outside the tap mask; fn mismatches still count.
    let flags = random.chance(0.3) ? fnFlag.symmetricDifference(.maskSecondaryFn) : fnFlag
    return [.input(.mouseMoved, keyCode: 0, flags: flags, at: advance(0...100_000_000))]
  }
}

/// The gesture contract from SPEC section 5, written independently of the
/// monitor: a tap is a clean Globe down then Globe up below the snapshotted
/// threshold with no other key, modifier, system event, or Fn discontinuity.
private struct GestureOracle {
  static let modifierMask: CGEventFlags = [
    .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskHelp,
  ]

  var threshold: Int
  private(set) var fnDown = false
  private(set) var heldKeys: Set<Int64> = []
  private var candidate: (start: UInt64, threshold: Int)?

  init(threshold: Int) {
    self.threshold = min(max(threshold, 50), 300)
  }

  mutating func receive(
    type: CGEventType,
    keyCode: Int64,
    flags: CGEventFlags,
    at timestamp: UInt64
  ) -> GlobeTap? {
    let eventFn = flags.contains(.maskSecondaryFn)
    let modifierHeld = !flags.intersection(Self.modifierMask).isEmpty
    defer { fnDown = eventFn }

    guard type == .flagsChanged else {
      if eventFn != fnDown { candidate = nil }
      switch type {
      case .keyDown where keyCode <= 126:
        candidate = nil
        if keyCode != 63 { heldKeys.insert(keyCode) }
      case .keyUp where keyCode <= 126:
        candidate = nil
        heldKeys.remove(keyCode)
      case _ where type.rawValue == 14:
        candidate = nil
      default:
        break
      }
      return nil
    }

    guard keyCode == 63, eventFn != fnDown else {
      candidate = nil
      return nil
    }
    if eventFn {
      candidate =
        heldKeys.isEmpty && !modifierHeld ? (timestamp, threshold) : nil
      return nil
    }
    defer { candidate = nil }
    guard let candidate, heldKeys.isEmpty, !modifierHeld,
      timestamp >= candidate.start,
      timestamp - candidate.start < UInt64(candidate.threshold) * 1_000_000
    else {
      return nil
    }
    return GlobeTap(
      keyUpTimestamp: timestamp,
      thresholdMilliseconds: candidate.threshold
    )
  }
}

/// Drives `GlobeEventMonitor.receive(type:event:)` with synthesized events.
/// Nothing is posted and no event tap is created.
private final class MonitorProbe: @unchecked Sendable {
  let monitor = GlobeEventMonitor()
  let threshold: Int
  private(set) var taps: [GlobeTap] = []
  private(set) var calibrationEvents: [GlobeEventMonitor.CalibrationEvent] = []

  init(threshold: Int = 150) {
    self.threshold = threshold
    monitor.updateThreshold(threshold)
    monitor.installCallbacksWithoutEventTap(
      onTap: { [unowned self] in self.taps.append($0) },
      onCalibrationEvent: { [unowned self] in
        self.calibrationEvents.append($0)
      }
    )
  }

  func globe(down: Bool, at timestamp: UInt64, extraFlags: CGEventFlags = []) {
    send(
      .flagsChanged,
      keyCode: 63,
      flags: (down ? CGEventFlags.maskSecondaryFn : []).union(extraFlags),
      at: timestamp
    )
  }

  func key(_ keyCode: Int64, down: Bool, at timestamp: UInt64, fn: Bool = false) {
    send(
      down ? .keyDown : .keyUp,
      keyCode: keyCode,
      flags: fn ? .maskSecondaryFn : [],
      at: timestamp
    )
  }

  func send(
    _ type: CGEventType,
    keyCode: Int64,
    flags: CGEventFlags,
    at timestamp: UInt64
  ) {
    let event = CGEvent(source: nil)!
    event.type = type
    event.flags = flags
    event.timestamp = timestamp
    event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
    monitor.receive(type: type, event: event)
  }
}

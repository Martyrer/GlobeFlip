import Foundation

// SplitMix64 lives in Tests/GlobeFlipCoreTests/FuzzSupport.swift; both
// directories build into the same test target.
extension SplitMix64 {
  mutating func chance(_ probability: Double) -> Bool {
    Double.random(in: 0..<1, using: &self) < probability
  }
}

/// Fuzz configuration. xcodebuild forwards `TEST_RUNNER_`-prefixed variables
/// to the test process, so a long local run is:
/// `TEST_RUNNER_GLOBEFLIP_FUZZ_ITERATIONS=5000 xcodebuild ... test`.
/// `GLOBEFLIP_FUZZ_SEED` replays one failing iteration's printed seed.
enum AppFuzz {
  static func iterations(default defaultValue: Int) -> Int {
    if environmentSeed != nil { return 1 }
    guard
      let value = ProcessInfo.processInfo
        .environment["GLOBEFLIP_FUZZ_ITERATIONS"],
      let iterations = Int(value),
      iterations > 0
    else {
      return defaultValue
    }
    return iterations
  }

  static func seed(forIteration iteration: Int) -> UInt64 {
    if let environmentSeed { return environmentSeed }
    var generator = SplitMix64(seed: 0x476C_6F62_6546_6C69 &+ UInt64(iteration))
    return generator.next()
  }

  private static var environmentSeed: UInt64? {
    ProcessInfo.processInfo.environment["GLOBEFLIP_FUZZ_SEED"]
      .flatMap { UInt64($0) }
  }
}

/// Runs every main-queue block enqueued before this call, including
/// `DispatchQueue.main.async` hops made by runtime callbacks.
@MainActor
func drainMainQueue() async {
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async { continuation.resume() }
  }
}

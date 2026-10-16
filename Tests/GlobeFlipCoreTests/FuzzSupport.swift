import Foundation
import Testing

/// SplitMix64: tiny seeded generator so every fuzz case replays exactly.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// Runs `body` once per case with a generator seeded from that case alone.
///
/// Failures carry the case seed. Replay one case with
/// `GLOBEFLIP_FUZZ_SEED=<seed> GLOBEFLIP_FUZZ_ITERATIONS=1`; run longer with a
/// larger `GLOBEFLIP_FUZZ_ITERATIONS` (prefix both with `TEST_RUNNER_` when
/// passing them through `xcodebuild`). Use `#require` in the body so the first
/// failing case stops the loop.
func fuzz(
  iterations defaultIterations: Int,
  _ body: (inout SplitMix64, Comment) throws -> Void
) throws {
  let environment = ProcessInfo.processInfo.environment
  let iterations =
    environment["GLOBEFLIP_FUZZ_ITERATIONS"].flatMap { Int($0) }
    ?? defaultIterations
  let baseSeed =
    environment["GLOBEFLIP_FUZZ_SEED"].flatMap { UInt64($0) }
    ?? 0x476C_6F62_6546_6C70
  for index in 0..<max(iterations, 0) {
    let seed = baseSeed &+ UInt64(index)
    var generator = SplitMix64(seed: seed)
    try body(&generator, "fuzz seed \(seed)")
  }
}

extension RandomNumberGenerator {
  /// True with probability `1 / n`.
  mutating func oneIn(_ n: UInt64) -> Bool {
    next() % n == 0
  }
}

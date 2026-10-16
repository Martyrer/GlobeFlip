import Testing

@testable import GlobeFlipCore

@Suite("Timing calibration")
struct TimingCalibrationTests {
  @Test("Rounds max plus margin to ten milliseconds")
  func recommendation() {
    #expect(
      TimingCalibration.recommendedThreshold(
        samples: [75, 88, 102, 121, 134]
      ) == 160
    )
    // 125 + 25 lands on a step; 126 + 25 rounds up, never to nearest.
    #expect(
      TimingCalibration.recommendedThreshold(
        samples: [100, 110, 120, 124, 125]
      ) == 150
    )
    #expect(
      TimingCalibration.recommendedThreshold(
        samples: [100, 110, 120, 124, 126]
      ) == 160
    )
  }

  @Test("Requires exactly five samples")
  func sampleCount() {
    for samples: [Double] in [[], [100, 110], [1, 2, 3, 4], [1, 2, 3, 4, 5, 6]] {
      #expect(TimingCalibration.recommendedThreshold(samples: samples) == nil)
    }
  }

  @Test("Clamps result to 50-300 ms")
  func clamping() {
    #expect(
      TimingCalibration.recommendedThreshold(samples: [0, 1, 2, 3, 4]) == 50
    )
    #expect(
      TimingCalibration.recommendedThreshold(samples: [0, 0, 0, 0, 25]) == 50
    )
    #expect(
      TimingCalibration.recommendedThreshold(samples: [0, 0, 0, 0, 26]) == 60
    )
    #expect(
      TimingCalibration.recommendedThreshold(samples: [0, 0, 0, 0, 275]) == 300
    )
    #expect(
      TimingCalibration.recommendedThreshold(
        samples: [260, 270, 280, 290, 310]
      ) == 300
    )
  }

  @Test("Huge finite samples clamp instead of trapping")
  func hugeSamples() {
    for huge in [1e19, 1e300, Double.greatestFiniteMagnitude] {
      #expect(
        TimingCalibration.recommendedThreshold(
          samples: [10, 20, 30, 40, huge]
        ) == 300
      )
    }
  }

  @Test("Rejects non-finite and negative samples")
  func nonFiniteValues() {
    for invalid in [Double.nan, .infinity, -.infinity, -1, -.leastNonzeroMagnitude] {
      #expect(
        TimingCalibration.recommendedThreshold(
          samples: [10, 20, 30, 40, invalid]
        ) == nil
      )
    }
  }

  @Test("Fuzz: result is nil for bad input, else a clamped 10 ms step")
  func fuzzRecommendation() throws {
    try fuzz(iterations: 5_000) { rng, seed in
      let count = rng.oneIn(4) ? Int.random(in: 0...8, using: &rng) : 5
      let samples: [Double] = (0..<count).map { _ in
        switch rng.next() % 10 {
        case 0:
          [
            .nan, .infinity, -.infinity, -1, -0.0, 0,
            .leastNonzeroMagnitude, .greatestFiniteMagnitude,
          ].randomElement(using: &rng)!
        case 1:
          Double(bitPattern: rng.next())
        default:
          Double.random(in: 0...400, using: &rng)
        }
      }

      let result = TimingCalibration.recommendedThreshold(samples: samples)

      let valid = count == 5 && samples.allSatisfy { $0.isFinite && $0 >= 0 }
      guard valid else {
        try #require(result == nil, seed)
        return
      }
      let threshold = try #require(result, seed)
      let target = samples.max()! + 25
      try #require((50...300).contains(threshold), seed)
      try #require(threshold % 10 == 0, seed)
      // Covers the slowest press plus margin unless clamped at 300, and is
      // the smallest such step unless clamped at 50.
      try #require(threshold == 300 || Double(threshold) >= target, seed)
      try #require(threshold == 50 || Double(threshold - 10) < target, seed)
    }
  }
}

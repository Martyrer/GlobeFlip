import Foundation

public enum TimingCalibration {
  public static let requiredSampleCount = 5
  public static let allowedRange = 50...300
  public static let defaultThresholdMilliseconds = 150

  public static func recommendedThreshold(
    samples: [Double]
  ) -> Int? {
    guard samples.count == requiredSampleCount,
      samples.allSatisfy({ $0.isFinite && $0 >= 0 }),
      let maximum = samples.max()
    else {
      return nil
    }

    // Clamp before converting so a huge finite sample cannot trap in Int().
    let rounded = ceil((maximum + 25) / 10) * 10
    return Int(
      min(
        max(rounded, Double(allowedRange.lowerBound)),
        Double(allowedRange.upperBound)
      )
    )
  }
}

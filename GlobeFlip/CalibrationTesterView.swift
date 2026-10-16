import GlobeFlipCore
import SwiftUI

struct CalibrationTesterView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var runtime: RuntimeCoordinator

  var body: some View {
    VStack(spacing: 0) {
      CalibrationPanel()
        .padding(24)

      Divider()

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Apply") {
          runtime.applyCalibration()
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(runtime.calibrationSuggestedThreshold == nil)
      }
      .padding(16)
    }
    .frame(width: 560, height: 430)
    .onAppear {
      runtime.startCalibration()
    }
    .onDisappear {
      runtime.stopCalibration()
    }
  }
}

struct CalibrationPanel: View {
  @EnvironmentObject private var preferences: PreferencesStore
  @EnvironmentObject private var runtime: RuntimeCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Globe Press Test")
          .font(.title2)
          .fontWeight(.semibold)
        Text("Press Globe/Fn five times at your normal speed.")
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 16) {
        Image(systemName: "globe")
          .font(.system(size: 30))
          .foregroundStyle(
            runtime.calibrationPressStartedAt == nil
              ? Color.secondary
              : Color.accentColor
          )
          .accessibilityHidden(true)

        Text(pressStatus)
          .font(.headline)
          .frame(height: 20)

        PressDurationMeter(
          pressStartedAt: runtime.calibrationPressStartedAt,
          lastDuration: runtime.calibrationSamples.last,
          threshold: preferences.tapThresholdMilliseconds
        )
      }

      sampleSlots

      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Recommended Threshold")
            .foregroundStyle(.secondary)
          Text(recommendation)
            .font(.title3)
            .fontWeight(.semibold)
            .monospacedDigit()
        }

        Spacer()

        Button {
          runtime.resetCalibration()
        } label: {
          Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .disabled(runtime.calibrationSamples.isEmpty)
      }

      Spacer()
    }
  }

  private var pressStatus: String {
    if runtime.calibrationSamples.count == TimingCalibration.requiredSampleCount {
      return "Test Complete"
    }
    if runtime.calibrationPressStartedAt != nil {
      return "Holding..."
    }
    return "Press Globe/Fn"
  }

  private var recommendation: String {
    runtime.calibrationSuggestedThreshold.map { "\($0) ms" } ?? "Complete 5 presses"
  }

  private var sampleSlots: some View {
    HStack(spacing: 8) {
      ForEach(0..<TimingCalibration.requiredSampleCount, id: \.self) { index in
        VStack(spacing: 4) {
          Text("\(index + 1)")
            .font(.caption)
            .foregroundStyle(.secondary)

          if runtime.calibrationSamples.indices.contains(index) {
            Text(
              "\(Int(runtime.calibrationSamples[index].rounded())) ms"
            )
            .font(.body)
            .monospacedDigit()
          } else {
            Text("--")
              .foregroundStyle(.tertiary)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Press samples")
  }
}

private struct PressDurationMeter: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let pressStartedAt: UInt64?
  let lastDuration: Double?
  let threshold: Int

  var body: some View {
    Group {
      if reduceMotion {
        meter(duration: lastDuration)
      } else {
        TimelineView(
          .animation(
            minimumInterval: 1 / 60,
            paused: pressStartedAt == nil
          )
        ) { _ in
          meter(duration: displayedDuration)
        }
      }
    }
  }

  private func meter(duration: Double?) -> some View {
    VStack(spacing: 6) {
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(
              LinearGradient(
                colors: [.green, .yellow, .orange, .red],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(height: 7)
            .offset(y: 4)

          Rectangle()
            .fill(.primary)
            .frame(width: 1, height: 15)
            .offset(
              x: markerOffset(
                Double(threshold),
                width: max(geometry.size.width - 1, 0)
              )
            )

          if let duration {
            Circle()
              .fill(Color(nsColor: .windowBackgroundColor))
              .overlay {
                Circle().stroke(.primary, lineWidth: 1.5)
              }
              .frame(width: 15, height: 15)
              .offset(
                x: markerOffset(
                  duration,
                  width: max(geometry.size.width - 15, 0)
                )
              )
          }
        }
      }
      .frame(height: 15)

      HStack {
        Text("\(TimingCalibration.allowedRange.lowerBound) ms")
        Spacer()
        Text(duration.map { "\(Int($0.rounded())) ms" } ?? "Waiting")
          .monospacedDigit()
          .frame(width: 84)
        Spacer()
        Text("\(TimingCalibration.allowedRange.upperBound) ms")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Globe press duration")
    .accessibilityValue(
      duration.map { "\(Int($0.rounded())) milliseconds" } ?? "Waiting"
    )
  }

  private var displayedDuration: Double? {
    guard let pressStartedAt else { return lastDuration }
    let now = DispatchTime.now().uptimeNanoseconds
    guard now >= pressStartedAt else { return 0 }
    return Double(now - pressStartedAt) / 1_000_000
  }

  private func markerOffset(_ duration: Double, width: Double) -> Double {
    let lower = Double(TimingCalibration.allowedRange.lowerBound)
    let upper = Double(TimingCalibration.allowedRange.upperBound)
    let clamped = min(max(duration, lower), upper)
    return (clamped - lower) / (upper - lower) * width
  }
}

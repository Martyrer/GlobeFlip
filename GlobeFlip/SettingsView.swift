import GlobeFlipCore
import SwiftUI

struct SettingsView: View {
  private enum Page: String, CaseIterable, Identifiable {
    case general = "General"
    case inputSources = "Input Sources"
    case timing = "Timing"
    case feedback = "Feedback"
    case statistics = "Statistics"
    case diagnostics = "Diagnostics"

    var id: Self { self }

    var systemImage: String {
      switch self {
      case .general: "gearshape"
      case .inputSources: "keyboard"
      case .timing: "timer"
      case .feedback: "hand.tap"
      case .statistics: "chart.bar.xaxis"
      case .diagnostics: "stethoscope"
      }
    }
  }

  @EnvironmentObject private var preferences: PreferencesStore
  @EnvironmentObject private var runtime: RuntimeCoordinator
  @State private var selection: Page = .general
  @State private var showsCalibrationTester = false
  @State private var showsResetConfirmation = false
  @State private var showsStatisticsResetConfirmation = false

  var body: some View {
    TabView(selection: $selection) {
      ForEach(Page.allCases) { page in
        pageContent(page)
          .tabItem {
            Label(page.rawValue, systemImage: page.systemImage)
          }
          .tag(page)
      }
    }
    .frame(minWidth: 900, minHeight: 560)
  }

  @ViewBuilder
  private func pageContent(_ page: Page) -> some View {
    switch page {
    case .general:
      general
    case .inputSources:
      inputSources
    case .timing:
      timing
    case .feedback:
      feedback
    case .statistics:
      statistics
    case .diagnostics:
      diagnostics
    }
  }

  private var general: some View {
    Form {
      Section("Runtime") {
        LabeledContent("Status") {
          runtimeHealthLabel
        }

        Toggle(
          "Pause Switching",
          isOn: Binding(
            get: { preferences.switchingPaused },
            set: { runtime.setSwitchingPaused($0) }
          )
        )
        .disabled(!preferences.onboardingCompleted)
      }

      Section("Input Monitoring") {
        LabeledContent("Permission") {
          Text(
            runtime.eventMonitorHealth == .permissionRequired
              ? "Required"
              : "Granted"
          )
        }

        if runtime.eventMonitorHealth == .permissionRequired,
          !runtime.inputMonitoringRequestMade
        {
          Button("Allow Input Monitoring") {
            runtime.requestInputMonitoring()
          }
        } else if runtime.eventMonitorHealth == .permissionRequired {
          HStack {
            Button("Open System Settings") {
              runtime.openSystemSettings()
            }
            Button("Check Again") {
              runtime.checkAgain()
            }
          }
        } else if runtime.canCheckAgain {
          Button("Check Again") {
            runtime.checkAgain()
          }
        }
      }

      Section("System Globe Action") {
        Toggle(
          "Press Fn/Globe key is set to Do Nothing",
          isOn: Binding(
            get: { preferences.systemGlobeActionConfirmed },
            set: { runtime.setSystemGlobeActionConfirmed($0) }
          )
        )
        Text(
          "GlobeFlip cannot verify this setting through public macOS APIs."
        )
        .foregroundStyle(.secondary)

        Button("Open Keyboard Settings") {
          runtime.openKeyboardSettings()
        }
      }

      Section("Appearance") {
        Picker("Appearance", selection: $preferences.appearance) {
          ForEach(Appearance.allCases) { appearance in
            Label(appearance.title, systemImage: appearance.systemImage)
              .tag(appearance)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("Launch at Login") {
        LabeledContent("Status", value: runtime.launchAtLoginStatus.title)

        Toggle(
          "Launch at Login",
          isOn: Binding(
            get: { runtime.launchAtLoginStatus == .enabled },
            set: { runtime.setLaunchAtLogin($0) }
          )
        )

        if runtime.launchAtLoginStatus == .requiresApproval {
          Button("Open Login Items") {
            runtime.openLoginItemsSettings()
          }
        }
      }

      Section("Failure Notifications") {
        LabeledContent(
          "Status",
          value: runtime.notificationAuthorization.title
        )
        if runtime.notificationAuthorization == .notDetermined {
          Button("Enable Notifications") {
            runtime.requestFailureNotifications()
          }
        } else if runtime.notificationAuthorization == .denied {
          Button("Open Notification Settings") {
            runtime.openNotificationSettings()
          }
        }
      }

      Section("Defaults") {
        Button(role: .destructive) {
          showsResetConfirmation = true
        } label: {
          Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.leading, 12, for: .scrollContent)
    .alert(
      "Reset GlobeFlip to Defaults?",
      isPresented: $showsResetConfirmation
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Reset", role: .destructive) {
        runtime.resetPreferences()
      }
    } message: {
      Text(
        "App preferences and setup choices will be cleared. Permissions and Launch at Login will not change."
      )
    }
    .onAppear {
      runtime.refreshSystemState()
    }
  }

  private var timing: some View {
    Form {
      Section("Globe Tap") {
        LabeledContent("Threshold") {
          HStack(spacing: 12) {
            Slider(
              value: Binding(
                get: {
                  Double(preferences.tapThresholdMilliseconds)
                },
                set: { runtime.setTapThresholdMilliseconds(Int($0)) }
              ),
              in: Double(
                TimingCalibration.allowedRange.lowerBound)...Double(
                  TimingCalibration.allowedRange.upperBound),
              step: 10
            )
            .frame(minWidth: 280)

            Text("\(preferences.tapThresholdMilliseconds) ms")
              .monospacedDigit()
              .frame(width: 58, alignment: .trailing)
          }
        }

        LabeledContent(
          "Baseline",
          value: "\(PreferencesStore.defaultTapThresholdMilliseconds) ms"
        )

        Button {
          showsCalibrationTester = true
        } label: {
          Label("Run Press Test", systemImage: "waveform.path.ecg")
        }
        .disabled(runtime.eventMonitorHealth != .running)
      }
    }
    .formStyle(.grouped)
    .contentMargins(.leading, 12, for: .scrollContent)
    .sheet(isPresented: $showsCalibrationTester) {
      CalibrationTesterView()
    }
  }

  private var inputSources: some View {
    Form {
      Section("Switching Cycle") {
        if runtime.inputSourceSnapshot.sources.isEmpty {
          LabeledContent("Status", value: "No Eligible Input Sources")
        } else {
          InputSourceOrderView(snapshot: runtime.inputSourceSnapshot) {
            id,
            offset in
            runtime.moveInputSource(id: id, by: offset)
          }
        }
      }

      if runtime.inputSourceSnapshot.health != .ready {
        Section("Status") {
          Label(
            inputSourceHealthTitle,
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)

          Button("Check Again") {
            runtime.checkAgain()
          }
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.leading, 12, for: .scrollContent)
  }

  private var feedback: some View {
    FeedbackSettingsView(preferences: preferences, runtime: runtime)
  }

  private var diagnostics: some View {
    Form {
      if runtime.activeWarnings.isEmpty {
        Section("Status") {
          Label("Everything looks healthy", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text(
            "Setup checks are passing. Globe input is verified separately below."
          )
          .foregroundStyle(.secondary)
        }
      } else {
        Section("Needs Attention") {
          ForEach(
            runtime.activeWarnings.sorted { $0.rawValue < $1.rawValue },
            id: \.self
          ) { warning in
            VStack(alignment: .leading, spacing: 8) {
              Label(
                warning.notificationTitle,
                systemImage: "exclamationmark.triangle.fill"
              )
              .font(.headline)
              .foregroundStyle(.orange)

              Text(warning.notificationBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

              diagnosticActions(for: warning)
            }
            .padding(.vertical, 4)
          }
        }
      }

      Section("Event Tap") {
        LabeledContent("Health") {
          runtimeHealthLabel
        }
        LabeledContent("Last Globe Input") {
          if let lastGlobeInputAt = runtime.lastGlobeInputAt {
            Text(lastGlobeInputAt, style: .relative)
          } else {
            Text("Not received by current event tap")
              .foregroundStyle(.secondary)
          }
        }
        LabeledContent("Last Globe Down") {
          if let lastGlobeDownAt = runtime.lastGlobeDownAt {
            Text(
              runtime.lastGlobeDownBlockingInput
                ?? lastGlobeDownAt.formatted(
                  .relative(presentation: .named)
                )
            )
          } else {
            Text("Not received")
              .foregroundStyle(.secondary)
          }
        }
        LabeledContent("Last Globe Up") {
          if let lastGlobeUpAt = runtime.lastGlobeUpAt {
            Text(lastGlobeUpAt, style: .relative)
          } else {
            Text("Not received")
              .foregroundStyle(.secondary)
          }
        }

        Button {
          showsCalibrationTester = true
        } label: {
          Label("Run Press Test", systemImage: "waveform.path.ecg")
        }
        .disabled(runtime.eventMonitorHealth != .running)

        if runtime.eventMonitorHealth == .running {
          Button("Restart Event Tap") {
            runtime.restartEventTap()
          }
        } else if runtime.canCheckAgain {
          Button("Check Again") {
            runtime.checkAgain()
          }
        }
      }

      Section("Input Sources") {
        LabeledContent("Health", value: inputSourceHealthTitle)
        LabeledContent(
          "Eligible Sources",
          value: "\(runtime.inputSourceSnapshot.sources.count)"
        )
        if let result = runtime.lastSwitchResult {
          LabeledContent("Latest Switch") {
            Text(switchResultTitle(result))
          }
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.leading, 12, for: .scrollContent)
  }

  private var statistics: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
          ],
          spacing: 12
        ) {
          statisticTile(
            title: "Today",
            value: runtime.statistics.todayCount.formatted(),
            systemImage: "sun.max"
          )
          statisticTile(
            title: "This Month",
            value: runtime.statistics.monthCount.formatted(),
            systemImage: "calendar"
          )
          statisticTile(
            title: "This Year",
            value: runtime.statistics.yearCount.formatted(),
            systemImage: "calendar.badge.clock"
          )
          statisticTile(
            title: "All Time",
            value: runtime.statistics.totalCount.formatted(),
            systemImage: "infinity"
          )
        }

        statisticsSection("Estimated Time Saved") {
          statisticsRow(
            "Today",
            value: formattedDuration(runtime.statistics.todaySavedMilliseconds)
          )
          statisticsRow(
            "This Month",
            value: formattedDuration(runtime.statistics.monthSavedMilliseconds)
          )
          statisticsRow(
            "This Year",
            value: formattedDuration(runtime.statistics.yearSavedMilliseconds)
          )
          statisticsRow(
            "All Time",
            value: formattedDuration(runtime.statistics.totalSavedMilliseconds)
          )
          Text("Compared with a 1.0-second manual Input Source switch.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }

        statisticsSection("Activity") {
          statisticsRow(
            "Active Days",
            value: runtime.statistics.activeDays.formatted()
          )
          statisticsRow(
            "Best Day",
            value: "\(runtime.statistics.bestDayCount.formatted()) switches"
          )
          statisticsRow(
            "Average per Active Day",
            value: formattedDailyAverage
          )
        }

        Button(role: .destructive) {
          showsStatisticsResetConfirmation = true
        } label: {
          Label("Reset Statistics", systemImage: "trash")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentMargins(24, for: .scrollContent)
    .task(id: selection) {
      guard selection == .statistics else { return }
      while !Task.isCancelled {
        runtime.refreshStatistics()
        try? await Task.sleep(for: .seconds(2))
      }
    }
    .alert(
      "Reset All Statistics?",
      isPresented: $showsStatisticsResetConfirmation
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Reset", role: .destructive) {
        runtime.resetStatistics()
      }
    } message: {
      Text("Switch counts and estimated time saved will be permanently deleted.")
    }
  }

  private func statisticTile(
    title: String,
    value: String,
    systemImage: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.callout)
        .foregroundStyle(.secondary)

      Text(value)
        .font(.system(size: 30, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
    .padding(16)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  private func statisticsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)

      VStack(spacing: 8) {
        content()
      }
    }
  }

  private func statisticsRow(
    _ title: String,
    value: String
  ) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.quaternary, in: Capsule())
  }

  private var inputSourceHealthTitle: String {
    switch runtime.inputSourceSnapshot.health {
    case .ready:
      "Ready"
    case .insufficientSources:
      "At Least Two Sources Required"
    case .selectionFailed:
      "Selection Failed"
    case .conflict:
      "Competing Remapper Detected"
    }
  }

  private func switchResultTitle(_ result: InputSourceSwitchResult) -> String {
    if let latency = result.latencyMilliseconds {
      return String(format: "Confirmed in %.1f ms", latency)
    }
    return "Failed"
  }

  private var runtimeHealthLabel: some View {
    let status: (title: String, image: String, color: Color) =
      switch runtime.eventMonitorHealth {
      case .stopped:
        ("Stopped", "stop.circle.fill", .secondary)
      case .permissionRequired:
        ("Permission Required", "exclamationmark.circle.fill", .orange)
      case .starting:
        ("Starting", "clock.fill", .secondary)
      case .running:
        ("Healthy", "checkmark.circle.fill", .green)
      case .failed:
        ("Failed", "xmark.circle.fill", .red)
      }

    return Label(status.title, systemImage: status.image)
      .foregroundStyle(status.color)
  }

  @ViewBuilder
  private func diagnosticActions(for warning: FailureWarning) -> some View {
    HStack {
      switch warning {
      case .inputMonitoring:
        Button("Open Input Monitoring") {
          runtime.openSystemSettings()
        }
      case .insufficientSources, .sourceSelection:
        Button("Open Keyboard Settings") {
          runtime.openKeyboardSettings()
        }
      case .launchAtLogin:
        Button("Open Login Items") {
          runtime.openLoginItemsSettings()
        }
      case .systemGlobeAction:
        Button("Open Keyboard Settings") {
          runtime.openKeyboardSettings()
        }
      case .systemSettings:
        EmptyView()
      case .sourceConflict, .eventTap:
        EmptyView()
      }

      if runtime.canCheckAgain {
        Button("Check Again") {
          runtime.checkAgain()
        }
      }
    }
  }

  private func formattedDuration(_ milliseconds: Double) -> String {
    let seconds = Int((milliseconds / 1_000).rounded())
    if seconds < 60 {
      return String(format: "%.1f sec", milliseconds / 1_000)
    }
    if seconds < 3_600 {
      return "\(seconds / 60)m \(seconds % 60)s"
    }
    return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
  }

  private var formattedDailyAverage: String {
    guard runtime.statistics.activeDays > 0 else { return "0" }
    let average =
      Double(runtime.statistics.totalCount)
      / Double(runtime.statistics.activeDays)
    return String(format: "%.1f", average)
  }

}

private struct FeedbackSettingsView: View {
  @ObservedObject var preferences: PreferencesStore
  let runtime: RuntimeCoordinator

  var body: some View {
    Form {
      Section("Trackpad") {
        Toggle(
          "Haptic Feedback",
          isOn: Binding(
            get: { preferences.hapticEnabled },
            set: { runtime.setHapticEnabled($0) }
          )
        )

        Picker(
          "Pulse Count",
          selection: Binding(
            get: { preferences.hapticPulseCount },
            set: { runtime.setHapticPulseCount($0) }
          )
        ) {
          ForEach(PreferencesStore.hapticPulseCountRange, id: \.self) {
            Text("\($0)").tag($0)
          }
        }
        .pickerStyle(.segmented)
        .disabled(!preferences.hapticEnabled)
      }
    }
    .formStyle(.grouped)
    .contentMargins(.leading, 12, for: .scrollContent)
  }
}

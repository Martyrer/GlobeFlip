import AppKit
import GlobeFlipCore
import SwiftUI

struct OnboardingView: View {
  private enum Step: Int, CaseIterable {
    case globeAction
    case inputMonitoring
    case inputSources
    case timing
    case launchAtLogin
    case notifications
    case completion

    var title: String {
      switch self {
      case .globeAction: "Disable the System Globe Action"
      case .inputMonitoring: "Allow Input Monitoring"
      case .inputSources: "Confirm Switching Cycle"
      case .timing: "Tune Tap Timing"
      case .launchAtLogin: "Start Automatically"
      case .notifications: "Failure Alerts"
      case .completion: "GlobeFlip Is Ready"
      }
    }

    var detail: String {
      switch self {
      case .globeAction:
        "Prevent macOS and GlobeFlip from responding to the same Globe/Fn tap."
      case .inputMonitoring:
        "GlobeFlip needs permission to observe Globe/Fn without changing other keyboard input."
      case .inputSources:
        "Review the Input Sources GlobeFlip will cycle through."
      case .timing:
        "Press Globe/Fn five times at your normal speed."
      case .launchAtLogin:
        "Keep Globe switching available after every sign-in."
      case .notifications:
        "Show silent notifications only when GlobeFlip needs attention."
      case .completion:
        "Everything is configured. Start using GlobeFlip."
      }
    }

    var systemImage: String {
      switch self {
      case .globeAction: "globe"
      case .inputMonitoring: "keyboard.badge.eye"
      case .inputSources: "arrow.trianglehead.2.clockwise.rotate.90"
      case .timing: "timer"
      case .launchAtLogin: "power"
      case .notifications: "bell.badge"
      case .completion: "checkmark.circle.fill"
      }
    }
  }

  @Environment(\.dismissWindow) private var dismissWindow
  @EnvironmentObject private var preferences: PreferencesStore
  @EnvironmentObject private var runtime: RuntimeCoordinator
  @State private var step: Step = .globeAction

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      Group {
        switch step {
        case .globeAction:
          globeActionStep
        case .inputMonitoring:
          inputMonitoringStep
        case .inputSources:
          inputSourcesStep
        case .timing:
          timingStep
        case .launchAtLogin:
          launchAtLoginStep
        case .notifications:
          notificationsStep
        case .completion:
          completionStep
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(28)

      Divider()

      footer
    }
    .frame(minWidth: 640, minHeight: 560)
    .onAppear {
      NSApplication.shared.activate()
      runtime.refreshSystemState()
    }
    .onChange(of: runtime.eventMonitorHealth) { _, health in
      if health == .permissionRequired,
        step.rawValue > Step.inputMonitoring.rawValue
      {
        step = .inputMonitoring
      } else if case .failed = health,
        step.rawValue > Step.inputMonitoring.rawValue
      {
        step = .inputMonitoring
      }
    }
    .onChange(of: preferences.systemGlobeActionConfirmed) { _, confirmed in
      if !confirmed, step != .globeAction {
        step = .globeAction
      }
    }
    .onChange(of: runtime.inputSourceSnapshot.health) { _, health in
      if health != .ready, step.rawValue > Step.inputSources.rawValue {
        step = .inputSources
      }
    }
  }

  private var header: some View {
    HStack(spacing: 16) {
      Image(systemName: step.systemImage)
        .font(.system(size: 24))
        .foregroundStyle(.tint)
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(step.title)
          .font(.title2)
          .fontWeight(.semibold)
        Text(step.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 6) {
        Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
        ProgressView(
          value: Double(step.rawValue + 1),
          total: Double(Step.allCases.count)
        )
        .frame(width: 120)
      }
    }
    .padding(24)
  }

  private var inputMonitoringStep: some View {
    Form {
      Section {
        LabeledContent("Permission") {
          statusLabel(
            complete: runtime.eventMonitorHealth == .running,
            completeTitle: "Granted",
            pendingTitle: "Required"
          )
        }

        if runtime.eventMonitorHealth == .permissionRequired,
          !runtime.inputMonitoringRequestMade
        {
          Button("Allow Input Monitoring") {
            runtime.requestInputMonitoring()
          }
          .buttonStyle(.borderedProminent)
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
    }
    .formStyle(.grouped)
  }

  private var inputSourcesStep: some View {
    Form {
      Section("Switching Cycle") {
        if runtime.inputSourceSnapshot.sources.isEmpty {
          Text("No Eligible Input Sources")
            .foregroundStyle(.secondary)
        } else {
          InputSourceOrderView(snapshot: runtime.inputSourceSnapshot) {
            id,
            offset in
            runtime.moveInputSource(id: id, by: offset)
          }
        }
      }

      if runtime.inputSourceSnapshot.health != .ready {
        Section {
          Label(
            "At Least Two Sources Required",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
          Text("Enable at least two Input Sources, then check again.")
            .foregroundStyle(.secondary)

          Button("Check Again") {
            runtime.checkAgain()
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var globeActionStep: some View {
    Form {
      Section("System Keyboard Setting") {
        Text(
          "Open System Settings > Keyboard and set “Press Fn/Globe key to” to “Do Nothing”. macOS provides no public API for GlobeFlip to verify this setting."
        )
        .foregroundStyle(.secondary)

        Toggle(
          "I set Press Fn/Globe key to Do Nothing",
          isOn: $preferences.systemGlobeActionConfirmed
        )
      }

      Section {
        Button {
          runtime.openKeyboardSettings()
        } label: {
          Label("Open Keyboard Settings", systemImage: "gearshape")
        }
      }
    }
    .formStyle(.grouped)
  }

  private var timingStep: some View {
    CalibrationPanel()
      .onAppear {
        if runtime.calibrationSuggestedThreshold == nil {
          runtime.startCalibration()
        }
      }
      .onDisappear {
        runtime.stopCalibration()
      }
  }

  private var launchAtLoginStep: some View {
    Form {
      Section {
        LabeledContent("Status", value: runtime.launchAtLoginStatus.title)

        if runtime.launchAtLoginStatus == .enabled {
          Label("Launch at Login Enabled", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          HStack {
            Spacer()

            Button {
              if runtime.launchAtLoginStatus == .requiresApproval {
                runtime.openLoginItemsSettings()
              } else {
                runtime.setLaunchAtLogin(true)
              }
            } label: {
              Label(
                runtime.launchAtLoginStatus == .requiresApproval
                  ? "Open Login Items"
                  : "Enable at Login",
                systemImage: runtime.launchAtLoginStatus == .requiresApproval
                  ? "gearshape"
                  : "power"
              )
              .frame(minWidth: 200)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(runtime.launchAtLoginStatus == .unavailable)

            Spacer()
          }
          .padding(.vertical, 8)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var notificationsStep: some View {
    Form {
      Section {
        LabeledContent(
          "Status",
          value: runtime.notificationAuthorization.title
        )

        if runtime.notificationAuthorization == .authorized {
          Label("Failure Notifications Enabled", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          if runtime.notificationAuthorization == .denied {
            Text(
              "macOS requires this permission to be restored in System Settings. GlobeFlip will open its notification switch directly."
            )
            .foregroundStyle(.secondary)
          }

          HStack {
            Spacer()

            Button {
              if runtime.notificationAuthorization == .denied {
                runtime.openNotificationSettings()
              } else {
                runtime.requestFailureNotifications()
              }
            } label: {
              Label(
                runtime.notificationAuthorization == .denied
                  ? "Allow Notifications in System Settings"
                  : "Enable Notifications",
                systemImage: runtime.notificationAuthorization == .denied
                  ? "gearshape"
                  : "bell.badge"
              )
              .frame(minWidth: 220)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()
          }
          .padding(.vertical, 8)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var completionStep: some View {
    VStack(spacing: 18) {
      Spacer()

      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 72))
        .foregroundStyle(.green)
        .accessibilityHidden(true)

      Text("You're All Set")
        .font(.largeTitle)
        .fontWeight(.semibold)

      Text(
        "GlobeFlip is configured and ready to switch Input Sources with the Globe/Fn key."
      )
      .font(.title3)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 460)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      Button("Back") {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
      }
      .disabled(step == .globeAction)

      Spacer()

      Button {
        advance()
      } label: {
        Text(primaryActionTitle)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(step == .completion ? .large : .regular)
      .keyboardShortcut(.defaultAction)
      .disabled(!canAdvance)
    }
    .padding(16)
  }

  private var canAdvance: Bool {
    switch step {
    case .globeAction:
      preferences.systemGlobeActionConfirmed
    case .inputMonitoring:
      runtime.eventMonitorHealth == .running
    case .inputSources:
      runtime.inputSourceSnapshot.health == .ready
    case .timing:
      runtime.calibrationSuggestedThreshold != nil
    case .launchAtLogin, .notifications:
      true
    case .completion:
      true
    }
  }

  private var primaryActionTitle: String {
    switch step {
    case .timing:
      "Apply & Continue"
    case .completion:
      "Start Using GlobeFlip"
    default:
      "Continue"
    }
  }

  private func advance() {
    guard canAdvance else { return }

    if step == .timing {
      runtime.applyCalibration()
    }

    if step == .completion {
      preferences.switchingPaused = false
      preferences.onboardingCompleted = true
      dismissWindow(id: "onboarding")
      return
    }

    if let next = Step(rawValue: step.rawValue + 1) {
      step = next
    }
  }

  private func statusLabel(
    complete: Bool,
    completeTitle: String,
    pendingTitle: String
  ) -> some View {
    Label(
      complete ? completeTitle : pendingTitle,
      systemImage: complete
        ? "checkmark.circle.fill"
        : "exclamationmark.circle.fill"
    )
    .foregroundStyle(complete ? Color.green : Color.orange)
  }
}

import AppKit
import GlobeFlipCore
import SwiftUI

struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @EnvironmentObject private var preferences: PreferencesStore
  @EnvironmentObject private var runtime: RuntimeCoordinator

  var body: some View {
    Group {
      runtimeStatus

      Divider()

      if runtime.canCheckAgain {
        Button {
          runtime.checkAgain()
        } label: {
          Label("Check Again", systemImage: "arrow.clockwise")
        }
      }

      if runtime.activeWarnings.contains(.launchAtLogin) {
        Button {
          runtime.openLoginItemsSettings()
        } label: {
          Label("Open Login Items", systemImage: "gearshape")
        }
      }

      if runtime.activeWarnings.contains(.inputMonitoring) {
        Button {
          runtime.openSystemSettings()
        } label: {
          Label("Open System Settings", systemImage: "gearshape")
        }
      }

      if runtime.activeWarnings.contains(.systemGlobeAction) {
        Button {
          runtime.openKeyboardSettings()
        } label: {
          Label("Open Keyboard Settings", systemImage: "keyboard")
        }
      }

      Button {
        runtime.setSwitchingPaused(!preferences.switchingPaused)
      } label: {
        Label(
          preferences.switchingPaused
            ? "Resume Switching"
            : "Pause Switching",
          systemImage: preferences.switchingPaused ? "play.fill" : "pause.fill"
        )
      }
      .disabled(!preferences.onboardingCompleted)

      if !preferences.onboardingCompleted {
        Button {
          NSApplication.shared.activate()
          openWindow(id: "onboarding")
        } label: {
          Label("Open Setup", systemImage: "checklist")
        }
      }

      Button {
        NSApplication.shared.activate()
        openSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .keyboardShortcut(",")

      Divider()

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Label("Quit GlobeFlip", systemImage: "power")
      }
      .keyboardShortcut("q")
    }
  }

  private var runtimeStatus: some View {
    let status: (title: String, image: String) =
      switch runtime.eventMonitorHealth {
      case .stopped:
        ("Stopped", "stop.circle.fill")
      case .permissionRequired:
        ("Input Monitoring Required", "exclamationmark.circle.fill")
      case .starting:
        ("Starting", "clock.fill")
      case .running:
        runtime.activeWarnings.isEmpty
          ? ("Monitoring", "checkmark.circle.fill")
          : ("Attention Required", "exclamationmark.circle.fill")
      case .failed:
        ("Attention Required", "xmark.circle.fill")
      }

    return Label(status.title, systemImage: status.image)
  }
}

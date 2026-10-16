import AppKit
import GlobeFlipCore
import SwiftUI

@main
@MainActor
struct GlobeFlipApp: App {
  @StateObject private var preferences: PreferencesStore
  @StateObject private var runtime: RuntimeCoordinator

  /// The test bundle is hosted by this app; keep the host's event tap, setup
  /// window, and notifications off so tests never touch the real runtime.
  private static let isHostingTests =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  init() {
    let preferences = PreferencesStore()
    let runtime = RuntimeCoordinator(
      preferences: preferences,
      activatesRuntime: !Self.isHostingTests
    )
    _preferences = StateObject(wrappedValue: preferences)
    _runtime = StateObject(wrappedValue: runtime)
  }

  var body: some Scene {
    MenuBarExtra("GlobeFlip", systemImage: "globe") {
      MenuBarView()
        .environmentObject(preferences)
        .environmentObject(runtime)
    }
    .menuBarExtraStyle(.menu)

    Window("GlobeFlip Setup", id: "onboarding") {
      OnboardingView()
        .environmentObject(preferences)
        .environmentObject(runtime)
    }
    .defaultSize(width: 680, height: 680)
    .defaultLaunchBehavior(
      preferences.onboardingCompleted || Self.isHostingTests
        ? .suppressed : .presented
    )
    .restorationBehavior(.disabled)

    Settings {
      SettingsView()
        .environmentObject(preferences)
        .environmentObject(runtime)
    }
    .defaultSize(width: 980, height: 640)
  }
}

extension Appearance {
  var appKitAppearance: NSAppearance? {
    switch self {
    case .system:
      nil
    case .light:
      NSAppearance(named: .aqua)
    case .dark:
      NSAppearance(named: .darkAqua)
    }
  }
}

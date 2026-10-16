import Foundation
import Testing

@testable import GlobeFlipCore

@Suite
struct AppearanceTests {
  @Test
  func casesKeepSettingsOrderAndTitles() {
    #expect(Appearance.allCases == [.system, .light, .dark])
    #expect(Appearance.allCases.map(\.title) == ["System", "Light", "Dark"])
  }

  /// Raw values are the persisted format; renaming one silently resets users.
  @Test
  @MainActor
  func eachAppearancePersistsByRawValue() {
    let suiteName = "AppearanceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    for (appearance, stored) in [
      (Appearance.light, "light"), (.dark, "dark"), (.system, "system"),
    ] {
      PreferencesStore(defaults: defaults).appearance = appearance
      #expect(defaults.string(forKey: "appearance") == stored)
      #expect(PreferencesStore(defaults: defaults).appearance == appearance)
    }
  }

  @Test
  func systemImagesAreDistinct() {
    #expect(Set(Appearance.allCases.map(\.systemImage)).count == 3)
  }
}

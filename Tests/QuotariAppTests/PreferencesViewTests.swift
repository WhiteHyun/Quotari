@testable import Quotari
import Testing

@MainActor
struct PreferencesViewTests {
  @Test func exposesTheRequiredSettingsTabs() {
    #expect(
      PreferencesTab.allCases == [
        .general,
        .accounts,
        .notifications,
        .about,
      ]
    )
    #expect(PreferencesTab.allCases.map(\.title) == [
      "General",
      "Accounts",
      "Notifications",
      "About",
    ])
    #expect(PreferencesTab.allCases.map(\.systemImage) == [
      "gearshape",
      "person.2",
      "bell",
      "info.circle",
    ])
  }
}

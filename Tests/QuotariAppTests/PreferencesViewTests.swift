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

  @Test func formatsPackagedVersionAndBuildMetadata() {
    let release = AppVersionInfo(infoDictionary: [
      "CFBundleShortVersionString": "0.1.2",
      "CFBundleVersion": "12",
    ])
    let matchingBuild = AppVersionInfo(infoDictionary: [
      "CFBundleShortVersionString": "0.1.2",
      "CFBundleVersion": "0.1.2",
    ])

    #expect(release?.displayVersion == "0.1.2 (12)")
    #expect(matchingBuild?.displayVersion == "0.1.2")
    #expect(AppVersionInfo(infoDictionary: [:]) == nil)
  }
}

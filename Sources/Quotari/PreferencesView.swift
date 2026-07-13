import AppKit
import Combine
import SwiftUI

enum PreferencesTab: CaseIterable, Hashable {
  case general
  case accounts
  case notifications
  case about

  var title: String {
    switch self {
    case .general: "General"
    case .accounts: "Accounts"
    case .notifications: "Notifications"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .accounts: "person.2"
    case .notifications: "bell"
    case .about: "info.circle"
    }
  }

  @MainActor @ViewBuilder
  var content: some View {
    switch self {
    case .general: GeneralPreferencesView()
    case .accounts: AccountsPreferencesView()
    case .notifications: NotificationsPreferencesView()
    case .about: AboutPreferencesView()
    }
  }
}

struct PreferencesView: View {
  @Environment(UsageStore.self) private var store
  @State private var selectedTab = PreferencesTab.general
  @Bindable private var loginItems = LoginItemController.shared

  var body: some View {
    TabView(selection: $selectedTab) {
      ForEach(PreferencesTab.allCases, id: \.self) { tab in
        tab.content
          .tabItem { Label(tab.title, systemImage: tab.systemImage) }
          .tag(tab)
      }
    }
    .frame(
      minWidth: 460,
      idealWidth: 500,
      minHeight: 420,
      idealHeight: 560
    )
    .onAppear { refreshExternalState() }
    // Coming back from System Settings (e.g. after approving the login item)
    // re-activates the app; that's the moment to pick up the outside change.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshExternalState()
    }
  }

  private func refreshExternalState() {
    loginItems.refreshStatus()
    Task { await store.quotaNotifications.refreshAuthorizationStatus() }
  }
}

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

  init(selectedTab: PreferencesTab = .general) {
    _selectedTab = State(initialValue: selectedTab)
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Rectangle()
        .fill(Theme.settingsSeparator)
        .frame(width: 1)
      detail
    }
    .background(Theme.settingsDetailBackground)
    .frame(
      minWidth: 840,
      idealWidth: 980,
      minHeight: 560,
      idealHeight: 680
    )
    .ignoresSafeArea(.container, edges: .top)
    .onAppear { refreshExternalState() }
    // Coming back from System Settings (e.g. after approving the login item)
    // re-activates the app; that's the moment to pick up the outside change.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshExternalState()
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 11) {
        Image(nsImage: IconRenderer.mascotIcon(frame: 0))
          .resizable()
          .interpolation(.high)
          .frame(width: 32, height: 32)
        Text("Quotari")
          .font(.title3.weight(.bold))
      }
      .padding(.horizontal, 22)
      .padding(.top, 54)
      .padding(.bottom, 28)

      VStack(spacing: 5) {
        ForEach(PreferencesTab.allCases, id: \.self) { tab in
          Button {
            selectedTab = tab
          } label: {
            HStack(spacing: 12) {
              Image(systemName: tab.systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 22)
              Text(tab.title)
                .font(.body.weight(selectedTab == tab ? .semibold : .regular))
              Spacer()
            }
            .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
            .background {
              if selectedTab == tab {
                LinearGradient(
                  colors: [Theme.brandAccentSecondary, Theme.brandAccent],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              }
            }
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
        }
      }
      .padding(.horizontal, 14)

      Spacer()
    }
    .frame(width: 230)
    .background(Theme.settingsSidebarBackground)
  }

  private var detail: some View {
    VStack(spacing: 0) {
      detailHeader
      ScrollView {
        selectedTab.content
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, 26)
          .padding(.bottom, 28)
      }
      .scrollIndicators(.hidden)
    }
  }

  private var detailHeader: some View {
    HStack(spacing: 18) {
      HStack(spacing: 0) {
        navigationButton(systemImage: "chevron.left", offset: -1)
        Rectangle()
          .fill(Theme.settingsSeparator)
          .frame(width: 1, height: 24)
        navigationButton(systemImage: "chevron.right", offset: 1)
      }
      .padding(4)
      .background(.regularMaterial, in: Capsule())
      .overlay { Capsule().stroke(Theme.settingsSeparator) }
      .shadow(color: .black.opacity(0.06), radius: 8, y: 2)

      Text(selectedTab.title)
        .font(.title2.weight(.bold))
        .contentTransition(.interpolate)
      Spacer()
    }
    .padding(.horizontal, 26)
    .padding(.top, 42)
    .padding(.bottom, 20)
  }

  private func navigationButton(systemImage: String, offset: Int) -> some View {
    Button {
      moveSelection(by: offset)
    } label: {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 34, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!canMoveSelection(by: offset))
  }

  private func canMoveSelection(by offset: Int) -> Bool {
    guard let index = PreferencesTab.allCases.firstIndex(of: selectedTab) else { return false }
    return PreferencesTab.allCases.indices.contains(index + offset)
  }

  private func moveSelection(by offset: Int) {
    guard let index = PreferencesTab.allCases.firstIndex(of: selectedTab),
          PreferencesTab.allCases.indices.contains(index + offset)
    else { return }
    selectedTab = PreferencesTab.allCases[index + offset]
  }

  private func refreshExternalState() {
    loginItems.refreshStatus()
    Task { await store.quotaNotifications.refreshAuthorizationStatus() }
  }
}

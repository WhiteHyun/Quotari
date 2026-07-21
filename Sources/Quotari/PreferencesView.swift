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
    case .general: L10n.string("General")
    case .accounts: L10n.string("Accounts")
    case .notifications: L10n.string("Notifications")
    case .about: L10n.string("About")
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
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .frame(
      minWidth: 840,
      idealWidth: 980,
      minHeight: 560,
      idealHeight: 680
    )
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
        Image(nsImage: IconRenderer.mascotArtwork(frame: 0))
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: 32, height: 32)
        Text("Quotari")
          .font(.title3.weight(.bold))
      }
      .padding(.horizontal, 18)
      .padding(.top, 18)
      .padding(.bottom, 14)

      List(selection: tabSelection) {
        ForEach(PreferencesTab.allCases, id: \.self) { tab in
          Label(tab.title, systemImage: tab.systemImage)
            .font(.body)
            .tag(tab)
        }
      }
      .listStyle(.sidebar)
      .tint(Theme.brandAccent)
    }
  }

  private var detail: some View {
    ScrollView {
      selectedTab.content
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 28)
    }
    .scrollIndicators(.hidden)
    .background(Theme.settingsDetailBackground)
    .navigationTitle(selectedTab.title)
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          moveSelection(by: -1)
        } label: {
          Label(L10n.string("Previous Section"), systemImage: "chevron.left")
        }
        .labelStyle(.iconOnly)
        .disabled(!canMoveSelection(by: -1))

        Button {
          moveSelection(by: 1)
        } label: {
          Label(L10n.string("Next Section"), systemImage: "chevron.right")
        }
        .labelStyle(.iconOnly)
        .disabled(!canMoveSelection(by: 1))
      }
    }
  }

  private var tabSelection: Binding<PreferencesTab?> {
    Binding(
      get: { selectedTab },
      set: { newValue in
        if let newValue {
          selectedTab = newValue
        }
      }
    )
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

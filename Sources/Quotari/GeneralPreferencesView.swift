import SwiftUI
import UniformTypeIdentifiers

struct GeneralPreferencesView: View {
  @Environment(UsageStore.self) private var store
  @State private var intervalMinutes: Double = 1
  @State private var importsCustomMascot = false
  @State private var mascotImportError: String?
  @Bindable private var loginItems = LoginItemController.shared

  var body: some View {
    @Bindable var menuBarPreferences = store.menuBarPreferences

    VStack(spacing: 16) {
      PreferencesCard(
        L10n.string("General"),
        subtitle: L10n.string("Choose how Quotari starts and stays available.")
      ) {
        PreferencesToggleRow(
          L10n.string("Launch at Login"),
          detail: L10n.string("Keep quota status ready from the moment you sign in."),
          isOn: $loginItems.launchesAtLogin
        )
        .disabled(!loginItems.isAvailable)
        loginItemStatus
      }

      PreferencesCard(
        L10n.string("Refresh"),
        subtitle: L10n.string("Control how often Quotari checks provider usage.")
      ) {
        VStack(alignment: .leading, spacing: 10) {
          Slider(value: $intervalMinutes, in: 1 ... 30, step: 1) {
            Text(L10n.string("Refresh interval"))
          } minimumValueLabel: {
            Text(L10n.string("1m"))
          } maximumValueLabel: {
            Text(L10n.string("30m"))
          }
          Text(L10n.string("Every \(Int(intervalMinutes)) minute(s)"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      PreferencesCard(
        L10n.string("Menu Bar"),
        subtitle: L10n.string("Tune the compact status shown beside the Quotari mascot.")
      ) {
        VStack(spacing: 16) {
          PreferencesToggleRow(
            L10n.string("Show remaining quota"),
            detail: L10n.string("Display the current remaining percentage in the menu bar."),
            isOn: $menuBarPreferences.showsRemainingPercent
          )
          PreferencesRowDivider()
          PreferencesControlRow(
            L10n.string("Quota source"),
            detail: L10n.string("Choose which provider drives the menu-bar percentage.")
          ) {
            Picker(L10n.string("Quota source"), selection: $menuBarPreferences.usageSource) {
              Text(L10n.string("Most constrained"))
                .tag(MenuBarUsageSource.mostConstrained)
              ForEach(store.enabledProviderDescriptors, id: \.id) { descriptor in
                Text(descriptor.metadata.displayName)
                  .tag(MenuBarUsageSource.provider(descriptor.id))
              }
            }
            .labelsHidden()
            .frame(width: 190, alignment: .trailing)
          }
          PreferencesRowDivider()
          PreferencesToggleRow(
            L10n.string("Animate mascot"),
            detail: L10n.string("Let the flame react as usage approaches its limit."),
            isOn: $menuBarPreferences.animatesMascot
          )
          PreferencesRowDivider()
          PreferencesControlRow(
            L10n.string("Mascot"),
            detail: L10n.string("Choose the built-in flame or your imported mascot.")
          ) {
            Picker(L10n.string("Mascot"), selection: $menuBarPreferences.mascot) {
              Text(L10n.string("Built-in Flame"))
                .tag(MenuBarMascot.builtIn)
              if menuBarPreferences.hasCustomMascot {
                Text(menuBarPreferences.customMascotName ?? L10n.string("Custom"))
                  .tag(MenuBarMascot.custom)
              }
            }
            .labelsHidden()
            .frame(width: 190, alignment: .trailing)
          }
          PreferencesRowDivider()
          PreferencesControlRow(
            L10n.string("Custom mascot"),
            detail: L10n.string(
              "Import 2–32 same-size PNG frames, or one horizontal sprite sheet with square frames."
            )
          ) {
            HStack(spacing: 8) {
              if menuBarPreferences.hasCustomMascot {
                Image(nsImage: menuBarPreferences.mascotIcon(frame: 0))
              }
              Button(
                menuBarPreferences.hasCustomMascot
                  ? L10n.string("Replace…")
                  : L10n.string("Import…")
              ) {
                importsCustomMascot = true
              }
              if menuBarPreferences.hasCustomMascot {
                Button(L10n.string("Remove"), role: .destructive) {
                  do {
                    try menuBarPreferences.removeCustomMascot()
                  } catch {
                    mascotImportError = error.localizedDescription
                  }
                }
              }
            }
          }
          PreferencesRowDivider()
          PreferencesControlRow(L10n.string("Open dashboard")) {
            DashboardShortcutRecorder()
              .frame(width: 130)
          }
        }
      }
    }
    .onAppear { intervalMinutes = store.refreshInterval / 60 }
    .onChange(of: intervalMinutes) { _, newValue in
      store.refreshInterval = newValue * 60
    }
    .fileImporter(
      isPresented: $importsCustomMascot,
      allowedContentTypes: [.png],
      allowsMultipleSelection: true
    ) { result in
      do {
        try menuBarPreferences.importCustomMascot(from: result.get())
      } catch {
        mascotImportError = error.localizedDescription
      }
    }
    .alert(
      L10n.string("Couldn’t import mascot"),
      isPresented: mascotImportErrorIsPresented
    ) {
      Button(L10n.string("OK"), role: .cancel) {}
    } message: {
      Text(mascotImportError ?? "")
    }
  }

  private var mascotImportErrorIsPresented: Binding<Bool> {
    Binding(
      get: { mascotImportError != nil },
      set: { isPresented in
        if !isPresented {
          mascotImportError = nil
        }
      }
    )
  }

  @ViewBuilder private var loginItemStatus: some View {
    if !loginItems.isAvailable {
      Text(L10n.string("Launch at Login is available in packaged releases."))
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if loginItems.requiresApproval {
      HStack(alignment: .firstTextBaseline) {
        Text(L10n.string("Approval is required in System Settings › Login Items."))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(L10n.string("Open System Settings…")) { loginItems.openSystemSettings() }
          .controlSize(.small)
      }
    } else if loginItems.serviceNotFound {
      Text(L10n
        .string("The login item could not be found. Toggling it again or reinstalling the app should restore it."))
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if let error = loginItems.lastError {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }
}

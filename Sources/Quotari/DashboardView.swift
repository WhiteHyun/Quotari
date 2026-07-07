import AppKit
import QuotariCore
import SwiftUI

struct DashboardView: View {
  var body: some View {
    ScrollView {
      DashboardContent()
    }
    .frame(width: 300)
    .frame(maxHeight: 560)
    .background(MenuVibrancyBackground())
  }
}

/// The popover's content at its natural height (no scroll cap). `DashboardView`
/// wraps this in a scroll view for the menu bar; snapshot tests render it directly.
struct DashboardContent: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(spacing: 0) {
      sectionStack
      Divider()
      actionRows
    }
    .frame(width: 300)
  }

  private var sectionStack: some View {
    VStack(spacing: 0) {
      let providers = store.providers
      ForEach(Array(providers.enumerated()), id: \.element.id) { index, descriptor in
        ProviderCardView(
          descriptor: descriptor,
          snapshot: store.snapshots[descriptor.id],
          sourceLabel: store.sourceLabels[descriptor.id],
          error: store.errors[descriptor.id]
        )
        if index < providers.count - 1 {
          Divider()
            .padding(.leading, 14)
        }
      }
    }
  }

  private var actionRows: some View {
    VStack(spacing: 1) {
      MenuActionRow(
        icon: "arrow.clockwise",
        title: "Refresh",
        shortcut: "⌘R",
        busy: store.isRefreshing
      ) {
        Task { await store.refresh() }
      }
      .keyboardShortcut("r")

      MenuActionRow(
        icon: "gearshape",
        title: "Settings…",
        shortcut: "⌘,"
      ) {
        openSettings()
      }
      .keyboardShortcut(",")

      MenuActionRow(
        icon: "power",
        title: "Quit Quotari",
        shortcut: "⌘Q"
      ) {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    .padding(6)
  }
}

private struct MenuVibrancyBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .menu
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct MenuActionRow: View {
  let icon: String
  let title: String
  let shortcut: String?
  var busy: Bool = false
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if busy {
          ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
        } else {
          Image(systemName: icon)
            .frame(width: 16)
        }
        Text(title)
        Spacer()
        if let shortcut {
          Text(shortcut)
            .foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
        }
      }
      .font(.body)
      .foregroundStyle(hovering ? Color.white : Color.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
      .background(
        hovering ? Color.accentColor : Color.clear,
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

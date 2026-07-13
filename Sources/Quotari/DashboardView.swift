import AppKit
import QuotariCore
import SwiftUI

struct DashboardView: View {
  /// The menu bar window resolves flexible height ranges to their minimum, so
  /// the window height must be a single measured value, not a min/max span.
  @State private var contentHeight: CGFloat = 100

  var body: some View {
    ScrollView {
      DashboardContent()
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          contentHeight = height
        }
    }
    .frame(width: 300)
    .frame(height: min(max(contentHeight, 100), 560))
    .background(MenuVibrancyBackground())
  }
}

/// The popover's content at its natural height (no scroll cap). `DashboardView`
/// wraps this in a scroll view for the menu bar; snapshot tests render it directly.
struct DashboardContent: View {
  @Environment(UsageStore.self) private var store

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
        store.beginRefresh()
      }
      .keyboardShortcut("r")

      MenuActionRow(
        icon: "gearshape",
        title: "Settings…",
        shortcut: "⌘,"
      ) {
        SettingsWindowController.shared.show(store: store)
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
      MenuActionLabel(
        icon: icon,
        title: title,
        shortcut: shortcut,
        busy: busy,
        highlighted: hovering
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

private struct MenuActionLabel: View {
  let icon: String
  let title: String
  let shortcut: String?
  let busy: Bool
  let highlighted: Bool

  var body: some View {
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
          .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
      }
    }
    .font(.body)
    .foregroundStyle(highlighted ? Color.white : Color.primary)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .background(
      highlighted ? Color.accentColor : Color.clear,
      in: RoundedRectangle(cornerRadius: 5, style: .continuous)
    )
  }
}

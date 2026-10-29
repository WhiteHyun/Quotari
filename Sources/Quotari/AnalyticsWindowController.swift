import AppKit
import Observation
import QuotariCore
import SwiftUI

/// What the Analytics window shows: a provider card's provider, account, and
/// period when opened from it.
struct AnalyticsContext: Equatable, Sendable {
  var provider: UsageProvider
  /// Nil follows the dashboard's account for the provider.
  var accountID: String?
  var period: UsageInsightsPeriod
}

enum AnalyticsAccountState: Equatable {
  case idle
  case loading
  case loaded(UsageInsightsSummary)
  /// No local logs can be attributed to the account.
  case unavailable
}

/// Window-local filters. Changing them never changes the dashboard's account.
@MainActor
@Observable
final class AnalyticsWindowModel {
  var context: AnalyticsContext
  /// Insights for an account other than the dashboard's, loaded on demand.
  var otherAccountState = AnalyticsAccountState.idle

  init(context: AnalyticsContext) {
    self.context = context
  }
}

@MainActor
final class AnalyticsWindowController {
  static let shared = AnalyticsWindowController()

  private var window: NSWindow?
  private(set) var model: AnalyticsWindowModel?

  var isVisible: Bool {
    window?.isVisible == true
  }

  var windowTitle: String? {
    window?.title
  }

  var isResizable: Bool {
    window?.styleMask.contains(.resizable) == true
  }

  var minimumContentSize: NSSize? {
    window?.contentMinSize
  }

  /// Opens the one Analytics window, or brings it forward with a new context.
  func show(store: UsageStore, context: AnalyticsContext) {
    if let model {
      model.context = context
      model.otherAccountState = .idle
    }
    let analyticsWindow = window ?? makeWindow(store: store, context: context)
    NSApplication.shared.activate(ignoringOtherApps: true)
    analyticsWindow.makeKeyAndOrderFront(nil)
  }

  func close() {
    window?.close()
  }

  private func makeWindow(store: UsageStore, context: AnalyticsContext) -> NSWindow {
    let model = AnalyticsWindowModel(context: context)
    let controller = NSHostingController(rootView: AnalyticsRootView(model: model).environment(store))
    let analyticsWindow = NSWindow(contentViewController: controller)
    analyticsWindow.title = L10n.string("Usage Analytics")
    analyticsWindow.identifier = NSUserInterfaceItemIdentifier("Quotari.Analytics")
    analyticsWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
    analyticsWindow.contentMinSize = NSSize(width: 680, height: 480)
    analyticsWindow.setContentSize(NSSize(width: 840, height: 620))
    analyticsWindow.isReleasedWhenClosed = false
    analyticsWindow.center()
    self.model = model
    window = analyticsWindow
    return analyticsWindow
  }
}

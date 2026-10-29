import Foundation
import QuotariCore

/// A suggested account switch, or why a switch from that suggestion failed.
struct AccountSwitchAlert: Equatable, Sendable {
  enum Content: Equatable, Sendable {
    case suggestion(window: QuotaNotificationWindow, remainingPercent: Int)
    case failed(reason: String)
  }

  static let categoryID = "quotari.accountSwitch"
  static let switchActionID = "quotari.accountSwitch.switch"
  /// Posted on the default center when the user picks the Switch action.
  static let switchRequested = Notification.Name("com.whitehyun.quotari.accountSwitchRequested")

  var provider: UsageProvider
  var accountID: String
  var accountName: String
  var content: Content

  /// One per provider: a newer suggestion replaces the older one.
  var requestID: String {
    "quotari.accountSwitch.\(provider.rawValue)"
  }
}

extension QuotaNotificationController {
  func deliverAccountSwitchAlert(_ alert: AccountSwitchAlert) async {
    guard preferences.isEnabled else { return }
    do {
      try await center.addAccountSwitchAlert(alert)
    } catch {
      lastError = error.localizedDescription
    }
  }
}

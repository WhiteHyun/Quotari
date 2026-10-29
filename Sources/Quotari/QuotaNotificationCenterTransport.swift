import Foundation
import QuotariCore
import QuotariSharedSnapshot
import UserNotifications

enum QuotaNotificationAuthorizationStatus: Equatable, Sendable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case ephemeral

  var allowsDelivery: Bool {
    switch self {
    case .authorized, .provisional, .ephemeral:
      true
    case .notDetermined, .denied:
      false
    }
  }
}

@MainActor
protocol QuotaNotificationCenterTransport: AnyObject {
  func authorizationStatus() async -> QuotaNotificationAuthorizationStatus
  func requestAuthorization() async throws -> Bool
  func pendingScheduledRequestIdentifiers() async -> Set<String>
  func add(_ request: QuotaNotificationRequest) async throws
  func addResetCreditReminder(_ reminder: ResetCreditReminder) async throws
  func addProviderStatusAlert(_ alert: ProviderStatusAlert) async throws
  func addSessionActivityAlert(_ alert: SessionActivityAlert) async throws
  func addAccountSwitchAlert(_ alert: AccountSwitchAlert) async throws
  func removePendingRequests(withIdentifiers identifiers: [String])
  func removeRequests(withIdentifiers identifiers: [String])
  func configureForegroundPresentation()
}

@MainActor
final class SystemQuotaNotificationCenter: QuotaNotificationCenterTransport {
  private let center: UNUserNotificationCenter
  private let foregroundDelegate = QuotaNotificationForegroundDelegate()

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func authorizationStatus() async -> QuotaNotificationAuthorizationStatus {
    let settings = await center.notificationSettings()
    return QuotaNotificationAuthorizationStatus(settings.authorizationStatus)
  }

  func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .sound])
  }

  func pendingScheduledRequestIdentifiers() async -> Set<String> {
    await Set(center.pendingNotificationRequests().compactMap { request in
      request.content.userInfo[UserInfoKey.kind] as? String == QuotaNotificationKind.weeklyReset.rawValue
        ? request.identifier
        : nil
    })
  }

  func add(_ request: QuotaNotificationRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = request.notificationTitle
    content.body = request.notificationBody
    content.sound = .default
    content.userInfo = [UserInfoKey.kind: request.kind.rawValue]
    let notification = UNNotificationRequest(
      identifier: request.requestID,
      content: content,
      trigger: request.notificationTrigger
    )
    try await center.add(notification)
  }

  func addResetCreditReminder(_ reminder: ResetCreditReminder) async throws {
    let content = UNMutableNotificationContent()
    content.title = reminder.notificationTitle
    content.body = reminder.notificationBody
    content.sound = .default
    // A distinct kind keeps reminders out of the weekly-reset reconciliation.
    content.userInfo = [UserInfoKey.kind: "resetCreditExpiring"]
    let notification = UNNotificationRequest(
      identifier: reminder.requestID,
      content: content,
      trigger: reminder.deliverAt.map(Self.calendarTrigger)
    )
    try await center.add(notification)
  }

  func addProviderStatusAlert(_ alert: ProviderStatusAlert) async throws {
    let content = UNMutableNotificationContent()
    content.title = alert.notificationTitle
    content.body = alert.notificationBody
    content.sound = .default
    content.userInfo = [UserInfoKey.kind: "providerStatus"]
    try await center.add(UNNotificationRequest(identifier: alert.requestID, content: content, trigger: nil))
  }

  func addSessionActivityAlert(_ alert: SessionActivityAlert) async throws {
    let content = UNMutableNotificationContent()
    content.title = alert.notificationTitle
    content.body = alert.notificationBody
    content.sound = .default
    content.threadIdentifier = alert.requestID
    content.userInfo = [UserInfoKey.kind: "sessionActivity"]
    try await center.add(UNNotificationRequest(identifier: alert.requestID, content: content, trigger: nil))
  }

  func addAccountSwitchAlert(_ alert: AccountSwitchAlert) async throws {
    let content = UNMutableNotificationContent()
    content.title = alert.notificationTitle
    content.body = alert.notificationBody
    content.sound = .default
    if case .suggestion = alert.content {
      content.categoryIdentifier = AccountSwitchAlert.categoryID
      content.userInfo = [
        UserInfoKey.kind: "accountSwitch",
        AccountSwitchAlert.UserInfoKey.provider: alert.provider.rawValue,
        AccountSwitchAlert.UserInfoKey.accountID: alert.accountID,
      ]
    }
    try await center.add(UNNotificationRequest(identifier: alert.requestID, content: content, trigger: nil))
  }

  nonisolated static func calendarTrigger(at date: Date) -> UNNotificationTrigger {
    let components = Calendar.current.dateComponents(
      [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
      from: date
    )
    return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
  }

  func removePendingRequests(withIdentifiers identifiers: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  func removeRequests(withIdentifiers identifiers: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
  }

  func configureForegroundPresentation() {
    center.delegate = foregroundDelegate
    let switchAction = UNNotificationAction(
      identifier: AccountSwitchAlert.switchActionID,
      title: L10n.string("Switch Account")
    )
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: AccountSwitchAlert.categoryID,
        actions: [switchAction],
        intentIdentifiers: []
      ),
    ])
  }

  private enum UserInfoKey {
    static let kind = "quotari.notification.kind"
  }
}

private final class QuotaNotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate,
  @unchecked Sendable {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  /// Hands a Switch action to the store, which runs the usual switch flow.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if response.actionIdentifier == AccountSwitchAlert.switchActionID,
       let provider = info[AccountSwitchAlert.UserInfoKey.provider] as? String,
       let accountID = info[AccountSwitchAlert.UserInfoKey.accountID] as? String {
      let userInfo = [
        AccountSwitchAlert.UserInfoKey.provider: provider,
        AccountSwitchAlert.UserInfoKey.accountID: accountID,
      ]
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: AccountSwitchAlert.switchRequested, object: nil, userInfo: userInfo)
      }
    }
    completionHandler()
  }
}

private extension QuotaNotificationAuthorizationStatus {
  init(_ status: UNAuthorizationStatus) {
    switch status {
    case .notDetermined:
      self = .notDetermined
    case .denied:
      self = .denied
    case .authorized:
      self = .authorized
    case .provisional:
      self = .provisional
    case .ephemeral:
      self = .ephemeral
    @unknown default:
      self = .denied
    }
  }
}

private extension QuotaNotificationRequest {
  var notificationTitle: String {
    switch kind {
    case .warning:
      L10n.string("\(providerName) quota warning")
    case .critical:
      L10n.string("\(providerName) quota almost exhausted")
    case .weeklyReset:
      L10n.string("\(providerName) weekly quota reset")
    }
  }

  var notificationBody: String {
    switch kind {
    case .warning, .critical:
      let used = observedUsedPercent.map { String(format: "%.0f", $0) } ?? "—"
      return L10n.string("\(windowName) usage is at \(used)%.")
    case .weeklyReset:
      return L10n.string("Your weekly quota has reset.")
    }
  }

  var notificationTrigger: UNNotificationTrigger? {
    deliverAt.map(SystemQuotaNotificationCenter.calendarTrigger)
  }

  private var providerName: String {
    switch key.provider {
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }

  private var windowName: String {
    switch key.window {
    case .session: L10n.string("Session")
    case .weekly: L10n.string("Weekly")
    }
  }
}

private extension ResetCreditReminder {
  var notificationTitle: String {
    L10n.string("\(providerName) reset credit expiring")
  }

  var notificationBody: String {
    L10n.string("A reset credit expires within a day. Redeem it in \(providerName) before it does.")
  }

  private var providerName: String {
    switch provider {
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }
}

private extension ProviderStatusAlert {
  var notificationTitle: String {
    switch event {
    case let .started(provider, _):
      L10n.string("\(provider.notificationName) service incident")
    case let .resolved(provider, _):
      L10n.string("\(provider.notificationName) service restored")
    }
  }

  var notificationBody: String {
    switch event {
    case let .started(_, title):
      L10n.string("\(title). Usage may fail or look stale until it's resolved.")
    case let .resolved(_, title):
      L10n.string("\(title) is resolved.")
    }
  }
}

extension AccountSwitchAlert {
  enum UserInfoKey {
    static let provider = "quotari.accountSwitch.provider"
    static let accountID = "quotari.accountSwitch.accountID"
  }
}

private extension AccountSwitchAlert {
  var notificationTitle: String {
    switch content {
    case .suggestion(.session, _):
      L10n.string("\(provider.notificationName) session quota is nearly out")
    case .suggestion(.weekly, _):
      L10n.string("\(provider.notificationName) weekly quota is nearly out")
    case .failed:
      L10n.string("Couldn't switch \(provider.notificationName) accounts")
    }
  }

  var notificationBody: String {
    switch content {
    case let .suggestion(_, remaining):
      L10n.string("\(accountName) has \(remaining)% left. Switch to keep working.")
    case let .failed(reason):
      reason
    }
  }
}

private extension SessionActivityAlert {
  var notificationTitle: String {
    switch event.kind {
    case .needsInput: L10n.string("Claude Code needs your input")
    case .finished: L10n.string("Claude Code finished")
    }
  }

  var notificationBody: String {
    guard let project = event.project else { return L10n.string("A session is waiting for you.") }
    return L10n.string("Session in \(project)")
  }
}

private extension UsageProvider {
  var notificationName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }
}

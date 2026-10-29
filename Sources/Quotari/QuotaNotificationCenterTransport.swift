import Foundation
import QuotariCore
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

private extension UsageProvider {
  var notificationName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }
}

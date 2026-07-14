import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

extension QuotaNotificationControllerTests {
  func makeDefaults(_ testName: String) throws -> UserDefaults {
    let suiteName = "QuotaNotificationControllerTests.\(testName)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  func snapshot(
    provider: UsageProvider = .codex,
    sessionUsed: Double? = nil,
    weeklyUsed: Double? = nil,
    resetAt: Date
  ) -> UsageSnapshot {
    UsageSnapshot(
      provider: provider,
      primary: sessionUsed.map {
        RateWindow(kind: .session, usedPercent: $0, resetsAt: resetAt)
      },
      secondary: weeklyUsed.map {
        RateWindow(kind: .weekly, usedPercent: $0, resetsAt: resetAt)
      },
      updatedAt: now
    )
  }
}

extension QuotaNotificationLedger {
  func scheduledID(provider: UsageProvider) -> String? {
    windows.first(where: { $0.key.provider == provider })?.value.scheduledReset?.requestID
  }
}

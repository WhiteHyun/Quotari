import Foundation
@testable import QuotariCore
import Testing

struct ClaudeExtraUsageParsingTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func reportsEnabledExtraUsageInCurrencyUnits() throws {
    // Synthetic values. Claude reports extra-usage amounts in cents.
    let usage = try ClaudeUsageParser.parse(claudeUsage(extraUsage: """
    { "is_enabled": true, "monthly_limit": 5000, "used_credits": 1250, "utilization": 25.0, "currency": "EUR" }
    """), provider: .claude, now: now)

    #expect(usage.extraUsage == ExtraUsage(used: 12.5, limit: 50, utilization: 25, currencyCode: "EUR"))
  }

  @Test func omitsDisabledExtraUsage() throws {
    let usage = try ClaudeUsageParser.parse(claudeUsage(extraUsage: """
    { "is_enabled": false, "monthly_limit": null, "used_credits": 0, "utilization": null }
    """), provider: .claude, now: now)

    #expect(usage.extraUsage == nil)
  }

  @Test func extraUsageIsNotReportedAsCost() throws {
    let usage = try ClaudeUsageParser.parse(claudeUsage(extraUsage: """
    { "is_enabled": true, "monthly_limit": 5000, "used_credits": 1250, "utilization": 25.0 }
    """), provider: .claude, now: now)

    #expect(usage.cost == nil)
  }

  @Test func keepsSpendWhenNoLimitIsReported() throws {
    let usage = try ClaudeUsageParser.parse(claudeUsage(extraUsage: """
    { "is_enabled": true, "monthly_limit": null, "used_credits": 399, "utilization": null }
    """), provider: .claude, now: now)

    #expect(usage.extraUsage == ExtraUsage(used: 3.99, limit: nil, utilization: nil, currencyCode: "USD"))
  }
}

struct CodexCreditsParsingTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func reportsCreditBalance() throws {
    let usage = try CodexUsageParser.parse(codexUsage(extraFields: """
    "credits": { "has_credits": true, "unlimited": false, "balance": "100" }
    """), provider: .codex, now: now)

    #expect(usage.credits == CreditBalance(balance: 100, isUnlimited: false))
  }

  @Test func omitsAccountsWithoutCredits() throws {
    let usage = try CodexUsageParser.parse(codexUsage(extraFields: """
    "credits": { "has_credits": false, "unlimited": false, "balance": "0" }
    """), provider: .codex, now: now)

    #expect(usage.credits == nil)
  }

  @Test func reportsAvailableResetCredits() throws {
    let usage = try CodexUsageParser.parse(codexUsage(extraFields: """
    "rate_limit_reset_credits": { "available_count": 2 }
    """), provider: .codex, now: now)

    #expect(usage.availableResetCredits == 2)
  }

  @Test func reportsUnlimitedCreditsWithoutBalance() throws {
    let usage = try CodexUsageParser.parse(codexUsage(extraFields: """
    "credits": { "has_credits": true, "unlimited": true, "balance": null }
    """), provider: .codex, now: now)

    #expect(usage.credits == CreditBalance(balance: nil, isUnlimited: true))
  }

  @Test func absentFieldsLeaveCreditsUnreported() throws {
    let usage = try CodexUsageParser.parse(codexUsage(extraFields: """
    "additional_rate_limits": null
    """), provider: .codex, now: now)

    #expect(usage.credits == nil)
    #expect(usage.availableResetCredits == nil)
  }
}

private func codexUsage(extraFields: String) -> Data {
  // Observed response shape; values are synthetic and contain no account data.
  Data("""
  {
    "plan_type": "plus",
    "rate_limit": {
      "primary_window": { "used_percent": 42, "limit_window_seconds": 18000, "reset_after_seconds": 3600 },
      "secondary_window": null
    },
    \(extraFields)
  }
  """.utf8)
}

private func claudeUsage(extraUsage: String) -> Data {
  Data("""
  {
    "five_hour": { "utilization": 10, "resets_at": "2027-01-15T08:00:00+00:00" },
    "extra_usage": \(extraUsage)
  }
  """.utf8)
}

import Foundation
@testable import Quotari
import QuotariCore
import Testing

struct ProviderBalanceRowsTests {
  private let english = Locale(identifier: "en_US")

  @Test func extraUsageShowsSpendAgainstItsLimit() {
    var snapshot = Self.snapshot(.claude)
    snapshot.extraUsage = ExtraUsage(used: 12.5, limit: 50, utilization: 25, currencyCode: "USD")

    #expect(ProviderBalanceRows.rows(for: snapshot, locale: english) == [
      ProviderBalanceRow(title: "Extra usage", value: "$12.50 of $50.00"),
    ])
  }

  @Test func codexShowsCreditBalanceAndResetCredits() {
    var snapshot = Self.snapshot(.codex)
    snapshot.credits = CreditBalance(balance: 1250, isUnlimited: false)
    snapshot.availableResetCredits = 2

    #expect(ProviderBalanceRows.rows(for: snapshot, locale: english) == [
      ProviderBalanceRow(title: "Credits", value: "1,250"),
      ProviderBalanceRow(title: "Reset credits", value: "2 available"),
    ])
  }

  @Test func unlimitedCreditsShowUnlimited() {
    var snapshot = Self.snapshot(.codex)
    snapshot.credits = CreditBalance(balance: nil, isUnlimited: true)

    #expect(ProviderBalanceRows.rows(for: snapshot, locale: english) == [
      ProviderBalanceRow(title: "Credits", value: "Unlimited"),
    ])
  }

  @Test func noResetCreditsShowsNoRow() {
    var snapshot = Self.snapshot(.codex)
    snapshot.availableResetCredits = 0

    #expect(ProviderBalanceRows.rows(for: snapshot, locale: english).isEmpty)
  }

  @Test func resetCreditsShowTheSoonestExpiry() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var snapshot = Self.snapshot(.codex)
    snapshot.availableResetCredits = 2
    snapshot.resetCreditExpiries = [
      ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval((3 * 24 + 4) * 3600)),
    ]

    #expect(ProviderBalanceRows.rows(for: snapshot, locale: english, now: now) == [
      ProviderBalanceRow(title: "Reset credits", value: "2 available · first expires in 3d 4h"),
    ])
  }

  @Test func soonestExpiryIsLocalizedInKorean() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var snapshot = Self.snapshot(.codex)
    snapshot.availableResetCredits = 2
    snapshot.resetCreditExpiries = [
      ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval((3 * 24 + 4) * 3600)),
    ]

    #expect(ProviderBalanceRows.rows(for: snapshot, locale: Locale(identifier: "ko"), now: now) == [
      ProviderBalanceRow(title: "리셋 크레딧", value: "2개 사용 가능 · 첫 만료까지 3일 4시간"),
    ])
  }

  @Test func rowsAreLocalizedInKorean() {
    var snapshot = Self.snapshot(.codex)
    snapshot.credits = CreditBalance(balance: nil, isUnlimited: true)
    snapshot.availableResetCredits = 1

    #expect(ProviderBalanceRows.rows(for: snapshot, locale: Locale(identifier: "ko")) == [
      ProviderBalanceRow(title: "크레딧", value: "무제한"),
      ProviderBalanceRow(title: "리셋 크레딧", value: "1개 사용 가능"),
    ])
  }

  private static func snapshot(_ provider: UsageProvider) -> UsageSnapshot {
    UsageSnapshot(provider: provider, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
  }
}

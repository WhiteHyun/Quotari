import Foundation
@testable import QuotariCore
import Testing

struct CostEstimateCoverageTests {
  @Test func classifiesCompletePartialAndUnavailableCoverage() {
    #expect(Self.coverage(priced: 100, unpriced: 0).availability == .complete)
    #expect(Self.coverage(priced: 100, unpriced: 50).availability == .partial)
    #expect(Self.coverage(priced: 0, unpriced: 50).availability == .unavailable)
  }

  @Test func unknownOnlySummaryHasUnavailableCost() throws {
    let calendar = Calendar(identifier: .gregorian)
    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_767_744_000))
    let summary = try #require(LocalCostSummaryBuilder.summary(
      provider: .codex,
      records: [LocalTokenRecord(
        day: day,
        model: "future-gpt",
        tokens: TokenTotals(input: 100, cacheRead: 0, cacheWrite: 0, output: 20)
      )],
      range: DayRange(start: day, end: day, calendar: calendar),
      pricing: LocalModelPricing()
    ))

    #expect(summary.monthSpend == 0)
    #expect(summary.estimateCoverage?.availability == .unavailable)
  }

  private static func coverage(priced: Int, unpriced: Int) -> CostEstimateCoverage {
    CostEstimateCoverage(pricedTokens: priced, unpricedTokens: unpriced)
  }
}

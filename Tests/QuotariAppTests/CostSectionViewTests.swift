@testable import Quotari
import QuotariCore
import SwiftUI
import Testing

@MainActor
struct CostSectionViewTests {
  @Test func unavailableCoverageHidesMoneyAndUsesUnavailableMessage() {
    let view = CostSectionView(
      cost: Self.cost(priced: 0, unpriced: 100),
      accent: .blue
    )

    #expect(view.showsMonetaryMetrics == false)
    #expect(view.pricingStatusMessage == "Cost unavailable · pricing unavailable for future-gpt")
  }

  @Test func mixedCoverageKeepsMoneyAndUsesPartialMessage() {
    let view = CostSectionView(
      cost: Self.cost(priced: 100, unpriced: 50),
      accent: .blue
    )

    #expect(view.showsMonetaryMetrics == true)
    #expect(view.pricingStatusMessage == "Partial estimate · pricing unavailable for future-gpt")
  }

  @Test func unsupportedMetricLimitationUsesPartialMessage() {
    var cost = Self.cost(priced: 100, unpriced: 0)
    cost.estimateLimitation = .unsupportedTokenFields
    let view = CostSectionView(cost: cost, accent: .blue)

    #expect(view.showsMonetaryMetrics == true)
    #expect(view.pricingStatusMessage == "Partial estimate · unsupported token fields")
  }

  private static func cost(priced: Int, unpriced: Int) -> CostSummary {
    CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: priced + unpriced,
      latestTokens: priced + unpriced,
      estimateCoverage: CostEstimateCoverage(
        pricedTokens: priced,
        unpricedTokens: unpriced,
        unpricedModels: ["future-gpt"]
      )
    )
  }
}

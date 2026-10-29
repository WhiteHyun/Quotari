import Foundation
@testable import QuotariCore
import Testing

struct UsageExportTests {
  private let start = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 / 86400 * 86400))

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }

  private var export: UsageExport {
    let partial = CostEstimateCoverage(pricedTokens: 800, unpricedTokens: 200, unpricedModels: ["new-model, preview"])
    return UsageExport(
      provider: .claude,
      source: .localClaudeCacheLogs,
      accountScope: .sharedLocalCache,
      days: [
        UsageInsightFixture.day(start, tokens: 4000, spend: .available(1.5)),
        UsageInsightFixture.day(
          start.addingTimeInterval(86400),
          tokens: 1000,
          spend: .partial(value: 0.25, limitation: .missingPricing),
          models: [
            ModelUsageInsight(
              modelID: "claude-opus-4-1",
              spend: .available(0.25),
              tokens: UsageInsightFixture.tokens(800),
              pricingCoverage: CostEstimateCoverage(pricedTokens: 800, unpricedTokens: 0)
            ),
          ],
          coverage: partial
        ),
      ]
    )
  }

  @Test func csvHasOneRowPerDayWithProvenanceAndCoverage() {
    #expect(export.csv(calendar: calendar) == """
    date,provider,source,account_scope,spend_usd,spend_status,input_tokens,output_tokens,cache_read_tokens,\
    cache_write_tokens,total_tokens,sessions,priced_tokens,unpriced_tokens,unpriced_models,stale_pricing,models
    2027-01-15,claude,localClaudeCacheLogs,sharedLocalCache,1.5000,available,2000,1000,1000,0,4000,1,4000,0,,false,
    2027-01-16,claude,localClaudeCacheLogs,sharedLocalCache,0.2500,partial:missingPricing,500,250,250,0,1000,1,800,200,\
    "new-model, preview",false,claude-opus-4-1

    """)
  }

  @Test func jsonCarriesTheModelBreakdownAndNoSessionFingerprints() throws {
    let data = try export.json(exportedAt: start.addingTimeInterval(2 * 86400), calendar: calendar)
    let text = try #require(String(bytes: data, encoding: .utf8))

    #expect(text == Self.expectedJSON)
  }

  private static let expectedJSON = """
  {
    "accountScope" : "sharedLocalCache",
    "days" : [
      {
        "date" : "2027-01-15",
        "models" : [

        ],
        "pricingCoverage" : {
          "pricedTokens" : 4000,
          "unpricedModels" : [

          ],
          "unpricedTokens" : 0,
          "usesStalePricing" : false
        },
        "sessions" : 1,
        "spendStatus" : "available",
        "spendUSD" : 1.5,
        "tokens" : {
          "cacheRead" : 1000,
          "cacheWrite" : 0,
          "input" : 2000,
          "output" : 1000,
          "total" : 4000
        }
      },
      {
        "date" : "2027-01-16",
        "models" : [
          {
            "model" : "claude-opus-4-1",
            "pricingCoverage" : {
              "pricedTokens" : 800,
              "unpricedModels" : [

              ],
              "unpricedTokens" : 0,
              "usesStalePricing" : false
            },
            "spendStatus" : "available",
            "spendUSD" : 0.25,
            "tokens" : {
              "cacheRead" : 200,
              "cacheWrite" : 0,
              "input" : 400,
              "output" : 200,
              "total" : 800
            }
          }
        ],
        "pricingCoverage" : {
          "pricedTokens" : 800,
          "unpricedModels" : [
            "new-model, preview"
          ],
          "unpricedTokens" : 200,
          "usesStalePricing" : false
        },
        "sessions" : 1,
        "spendStatus" : "partial:missingPricing",
        "spendUSD" : 0.25,
        "tokens" : {
          "cacheRead" : 250,
          "cacheWrite" : 0,
          "input" : 500,
          "output" : 250,
          "total" : 1000
        }
      }
    ],
    "exportedAt" : "2027-01-17T00:00:00Z",
    "provider" : "claude",
    "schemaVersion" : 1,
    "source" : "localClaudeCacheLogs"
  }
  """
}

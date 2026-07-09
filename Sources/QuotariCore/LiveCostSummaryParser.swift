import Foundation

enum LiveCostSummaryParser {
  static func parse(_ root: [String: Any], now: Date) -> CostSummary? {
    if let spend = root["spend"] as? [String: Any],
       let used = spend["used"] as? [String: Any],
       let summary = amountMinorSummary(from: used, now: now)
    {
      return summary
    }

    if let extra = root["extra_usage"] as? [String: Any],
       let usedCredits = number(extra["used_credits"]),
       let summary = reportedSpendSummary(
         amount: usedCredits,
         currencyCode: string(extra["currency"]) ?? "USD",
         now: now,
         sourceDescription: "Reported usage credits"
       )
    {
      return summary
    }

    return nil
  }

  private static func amountMinorSummary(from used: [String: Any], now: Date) -> CostSummary? {
    if let amountMinor = number(used["amount_minor"]) {
      let exponent = number(used["exponent"]) ?? 2
      guard exponent.isFinite else { return nil }
      return reportedSpendSummary(
        amount: amountMinor / pow(10, exponent),
        currencyCode: string(used["currency"]) ?? "USD",
        now: now,
        sourceDescription: "Reported by provider"
      )
    }

    if let amount = number(used["amount"]) ?? number(used["value"]) {
      return reportedSpendSummary(
        amount: amount,
        currencyCode: string(used["currency"]) ?? "USD",
        now: now,
        sourceDescription: "Reported by provider"
      )
    }

    return nil
  }

  private static func reportedSpendSummary(
    amount: Double,
    currencyCode: String,
    now: Date,
    sourceDescription: String
  ) -> CostSummary? {
    guard amount.isFinite, amount >= 0 else { return nil }
    let day = Calendar(identifier: .gregorian).startOfDay(for: now)
    return CostSummary(
      currencyCode: currencyCode.uppercased(),
      todaySpend: amount,
      monthSpend: amount,
      monthTokens: 0,
      latestTokens: 0,
      todaySpendLabel: "Reported",
      monthSpendLabel: "Period cost",
      sourceDescription: sourceDescription,
      daily: [DailyCost(date: day, spend: amount, tokens: 0)]
    )
  }

  private static func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private static func string(_ value: Any?) -> String? {
    (value as? String).flatMap { $0.isEmpty ? nil : $0 }
  }
}

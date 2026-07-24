import Foundation
import QuotariCore

enum UsageInsightsEmptyReason: Equatable {
  case noLocalUsage
}

extension UsageInsightsSummary {
  func matchesCalendarWindow(
    at now: Date,
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> Bool {
    guard let endDate = daily.last?.date else { return false }
    return calendar.isDate(endDate, inSameDayAs: now)
  }
}

enum UsageInsightsLoadState: Equatable {
  case idle
  case loading(cached: UsageInsightsSummary?)
  case loaded(UsageInsightsSummary)
  case empty(UsageInsightsEmptyReason)
  case failed(previous: UsageInsightsSummary?, message: String)

  var summary: UsageInsightsSummary? {
    switch self {
    case let .loading(cached), let .failed(cached, _):
      cached
    case let .loaded(summary):
      summary
    case .idle, .empty:
      nil
    }
  }

  var hasScopedSummary: Bool {
    summary != nil
  }

  func currentSummary(
    at now: Date,
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> UsageInsightsSummary? {
    guard let summary,
          summary.matchesCalendarWindow(at: now, calendar: calendar)
    else { return nil }
    return summary
  }
}

enum DashboardInsightsExpansion {
  static func initialProvider(
    enabledProviders: [UsageProvider],
    states: [UsageProvider: UsageInsightsLoadState],
    isRefreshing: Bool
  ) -> UsageProvider? {
    for provider in enabledProviders {
      let state = states[provider] ?? .idle
      if state.hasScopedSummary {
        return provider
      }
      switch state {
      case .loading:
        return nil
      case .idle where isRefreshing:
        return nil
      case .idle, .empty, .failed:
        continue
      case .loaded:
        return provider
      }
    }
    return nil
  }
}

import QuotariCore

enum UsageInsightsEmptyReason: Equatable {
  case noLocalUsage
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
}

enum DashboardInsightsExpansion {
  static func initialProvider(
    enabledProviders: [UsageProvider],
    states: [UsageProvider: UsageInsightsLoadState]
  ) -> UsageProvider? {
    enabledProviders.first {
      states[$0]?.hasScopedSummary == true
    }
  }
}

import Foundation

public struct LocalUsageCostEstimator: UsageCostEstimating, UsageInsightsAnalyzing {
  let environment: [String: String]
  let homeDirectory: URL
  let cacheDirectory: URL
  let insightsCacheDirectory: URL
  let pricingCatalogProvider: any ModelPricingCatalogProviding
  let cacheCoordinator: LocalUsageCacheCoordinator
  let scopeIdentityStore: LocalUsageScopeIdentityStore
  let cacheMutationHook: (@Sendable () -> Void)?

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    cacheDirectory: URL? = nil
  ) {
    let pricingCacheDirectory = homeDirectory
      .appendingPathComponent("Library/Caches/Quotari/ModelPricing", isDirectory: true)
    self.init(
      environment: environment,
      homeDirectory: homeDirectory,
      cacheDirectory: cacheDirectory,
      pricingCatalogProvider: RemoteModelPricingCatalogStore(cacheDirectory: pricingCacheDirectory),
      cacheMutationHook: nil
    )
  }

  init(
    environment: [String: String],
    homeDirectory: URL,
    cacheDirectory: URL? = nil,
    pricingCatalogProvider: any ModelPricingCatalogProviding,
    cacheMutationHook: (@Sendable () -> Void)? = nil
  ) {
    self.environment = environment
    self.homeDirectory = homeDirectory
    if let cacheDirectory {
      self.cacheDirectory = cacheDirectory
      insightsCacheDirectory = cacheDirectory.appendingPathComponent("insights", isDirectory: true)
    } else {
      self.cacheDirectory = homeDirectory
        .appendingPathComponent("Library/Caches/Quotari/LocalUsageCost", isDirectory: true)
      insightsCacheDirectory = homeDirectory
        .appendingPathComponent("Library/Caches/Quotari/LocalUsageInsights", isDirectory: true)
    }
    self.pricingCatalogProvider = pricingCatalogProvider
    cacheCoordinator = LocalUsageCacheCoordinator()
    scopeIdentityStore = LocalUsageScopeIdentityStore(cacheDirectory: insightsCacheDirectory)
    self.cacheMutationHook = cacheMutationHook
  }

  public func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int = 30) -> CostSummary? {
    cachedCostSummary(provider: provider, account: nil, now: now, historyDays: historyDays)
  }

  public func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) -> CostSummary? {
    guard let scope = resolvedInsightsScope(provider: provider, account: account) else { return nil }
    let historyDays = normalizedHistoryDays(historyDays)
    let mutationKey = LocalUsageCacheMutationKey(scopeKey: scope.key, historyDays: historyDays)
    return cacheCoordinator.read(key: mutationKey) {
      if let insights = LocalUsageInsightsCache(cacheDirectory: insightsCacheDirectory)
        .load(scopeKey: scope.key, now: now, historyDays: historyDays) {
        return insights.costSummary
      }
      return LocalUsageCostCache(cacheDirectory: cacheDirectory)
        .load(
          provider: provider,
          scopeID: scope.legacyCostScopeID,
          now: now,
          historyDays: historyDays
        )
    }
  }

  public func costSummary(provider: UsageProvider, now: Date, historyDays: Int = 30) async -> CostSummary? {
    await costSummary(provider: provider, account: nil, now: now, historyDays: historyDays)
  }

  public func costSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) async -> CostSummary? {
    let outcome = await costRefreshOutcome(
      provider: provider,
      account: account,
      now: now,
      historyDays: historyDays
    )
    guard case let .updated(summary) = outcome else { return nil }
    return summary
  }

  public func invalidateCachedCostSummary(provider: UsageProvider, historyDays: Int = 30) {
    invalidateCachedCostSummary(provider: provider, account: nil, historyDays: historyDays)
  }

  public func invalidateCachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int = 30
  ) {
    invalidateInsights(provider: provider, account: account, historyDays: historyDays)
  }
}

struct LocalUsageCostScanner {
  let environment: [String: String]
  let homeDirectory: URL
  let fileManager: FileManager
  private let calendar = Calendar(identifier: .gregorian)

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
  }

  func scan(
    provider: UsageProvider,
    account: ProviderAccount? = nil,
    now: Date,
    historyDays: Int = 30
  ) -> LocalUsageScan {
    let historyDays = max(1, min(365, historyDays))
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -(historyDays - 1), to: today) ?? today
    let range = DayRange(start: start, end: today, calendar: calendar)
    let outcome: LocalUsageScanOutcome = switch provider {
    case .codex:
      scanCodex(range: range, account: account)
    case .claude:
      scanClaude(range: range, account: account)
    }
    return LocalUsageScan(
      outcome: outcome,
      range: range,
      sourceDescription: sourceDescription(provider: provider, account: account)
    )
  }

  private func scanCodex(range: DayRange, account: ProviderAccount?) -> LocalUsageScanOutcome {
    scanFiles(roots: scopeRoots(provider: .codex, account: account), range: range) {
      parseCodexFile($0, range: range)
    }
  }

  private func scanClaude(range: DayRange, account: ProviderAccount?) -> LocalUsageScanOutcome {
    scanFiles(roots: scopeRoots(provider: .claude, account: account), range: range) {
      parseClaudeFile($0, range: range)
    }
  }

  private func scanFiles(
    roots: [URL],
    range: DayRange,
    parser: (URL) -> LocalUsageFileScan?
  ) -> LocalUsageScanOutcome {
    guard !roots.isEmpty else { return .noLocalLogs }
    let existingRoots = roots.filter { fileManager.fileExists(atPath: $0.path) }
    guard !existingRoots.isEmpty else { return .noLocalLogs }

    var scans: [LocalUsageFileScan] = []
    for root in existingRoots {
      guard let files = jsonlFiles(in: root, modifiedSince: range.start) else {
        return .failure
      }
      for file in files {
        guard let scan = parser(file) else { return .failure }
        scans.append(scan)
      }
    }

    let records = scans.flatMap(\.records)
    let unsupportedUsage = scans.flatMap(\.unsupportedUsage)
    if records.isEmpty, !unsupportedUsage.isEmpty {
      return .unsupportedUsage
    }
    return .success(LocalUsageScanResult(records: records, unsupportedUsage: unsupportedUsage))
  }

  private func jsonlFiles(in root: URL, modifiedSince: Date) -> [URL]? {
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsPackageDescendants]
    ) else { return nil }

    var urls: [URL] = []
    for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      if let modified = values?.contentModificationDate, modified < modifiedSince {
        continue
      }
      urls.append(url)
    }
    return urls.sorted { $0.path < $1.path }
  }
}

struct LocalUsageScan: Sendable {
  let outcome: LocalUsageScanOutcome
  let range: DayRange
  let sourceDescription: String?
}

enum LocalUsageScanOutcome: Sendable {
  case success(LocalUsageScanResult)
  case noLocalLogs
  case unsupportedUsage
  case failure
}

struct LocalUsageScanResult: Sendable {
  let records: [LocalTokenRecord]
  let unsupportedUsage: [LocalUnsupportedUsage]
}

struct LocalUnsupportedUsage: Sendable {
  let day: Date
  let model: String?
  let sessionID: String?
}

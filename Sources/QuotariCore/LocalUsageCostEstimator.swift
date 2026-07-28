import Darwin
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
    cachedCostSummary(
      provider: provider,
      account: account,
      credentialTransition: nil,
      now: now,
      historyDays: historyDays
    )
  }

  public func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int = 30
  ) -> CostSummary? {
    guard let scope = resolvedInsightsScope(
      provider: provider,
      account: account,
      credentialTransition: credentialTransition
    ) else { return nil }
    let historyDays = normalizedHistoryDays(historyDays)
    let mutationKey = LocalUsageCacheMutationKey(scopeKey: scope.key, historyDays: historyDays)
    return cacheCoordinator.read(key: mutationKey) {
      if let insights = LocalUsageInsightsCache(cacheDirectory: insightsCacheDirectory)
        .load(scopeKey: scope.key, now: now, historyDays: historyDays) {
        return insights.costSummary
      }
      let legacyCache = LocalUsageCostCache(cacheDirectory: cacheDirectory)
      if let current = legacyCache.load(
        provider: provider,
        scopeID: scope.legacyCostScopeID,
        now: now,
        historyDays: historyDays
      ) {
        return current
      }
      guard scope.previousCostScopeID != scope.legacyCostScopeID,
            let previous = legacyCache.load(
              provider: provider,
              scopeID: scope.previousCostScopeID,
              now: now,
              historyDays: historyDays
            )
      else { return nil }
      let migrated = legacyCache.save(
        previous,
        provider: provider,
        scopeID: scope.legacyCostScopeID,
        now: now,
        historyDays: historyDays
      )
      if migrated {
        legacyCache.remove(
          provider: provider,
          scopeID: scope.previousCostScopeID,
          historyDays: historyDays
        )
      }
      return previous
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
  let fileScanCache: LocalUsageFileScanCache?
  let onFileParsed: (@Sendable (URL) -> Void)?
  private let calendar = Calendar(identifier: .gregorian)

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    fileScanCacheDirectory: URL? = nil,
    onFileParsed: (@Sendable (URL) -> Void)? = nil
  ) {
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    fileScanCache = fileScanCacheDirectory.map {
      LocalUsageFileScanCache(cacheDirectory: $0, fileManager: fileManager)
    }
    self.onFileParsed = onFileParsed
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
    scanFiles(
      provider: .codex,
      roots: scopeRoots(provider: .codex, account: account),
      range: range,
      parser: { parseCodexFile($0, range: range) }
    )
  }

  private func scanClaude(range: DayRange, account: ProviderAccount?) -> LocalUsageScanOutcome {
    scanFiles(
      provider: .claude,
      roots: scopeRoots(provider: .claude, account: account),
      range: range,
      parser: { parseClaudeFile($0, range: range) }
    )
  }

  private func scanFiles(
    provider: UsageProvider,
    roots: [URL],
    range: DayRange,
    parser: (URL) -> LocalUsageFileParseOutcome
  ) -> LocalUsageScanOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard !roots.isEmpty else { return .noLocalLogs }
    let existingRoots = roots.filter { fileManager.fileExists(atPath: $0.path) }
    guard !existingRoots.isEmpty else { return .noLocalLogs }

    var scans: [LocalUsageFileScan] = []
    for root in existingRoots {
      switch scanRoot(root, provider: provider, range: range, parser: parser) {
      case let .success(rootScans):
        scans.append(contentsOf: rootScans)
      case .cancelled:
        return .cancelled
      case .failure:
        return .failure
      }
    }
    fileScanCache?.prune(olderThan: range.start)

    return aggregate(scans)
  }

  private func scanRoot(
    _ root: URL,
    provider: UsageProvider,
    range: DayRange,
    parser: (URL) -> LocalUsageFileParseOutcome
  ) -> LocalUsageFilesOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard let files = jsonlFiles(in: root, modifiedSince: range.start) else {
      return Task.isCancelled ? .cancelled : .failure
    }
    var scans: [LocalUsageFileScan] = []
    for file in files {
      let outcome = autoreleasepool {
        scanFile(file, provider: provider, range: range, parser: parser)
      }
      malloc_zone_pressure_relief(nil, 0)
      switch outcome {
      case let .success(scan):
        scans.append(scan)
      case .cancelled:
        return .cancelled
      case .failure:
        return .failure
      }
    }
    return .success(scans)
  }

  private func scanFile(
    _ file: URL,
    provider: UsageProvider,
    range: DayRange,
    parser: (URL) -> LocalUsageFileParseOutcome
  ) -> LocalUsageFileParseOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard let fingerprint = LocalUsageFileFingerprint(
      url: file,
      fileManager: fileManager
    ) else { return .failure }
    if let cached = fileScanCache?.load(
      provider: provider,
      url: file,
      fingerprint: fingerprint
    ) {
      return .success(cached.filtered(to: range))
    }
    switch parser(file) {
    case let .success(scan):
      guard !Task.isCancelled else { return .cancelled }
      onFileParsed?(file)
      fileScanCache?.save(
        scan,
        provider: provider,
        url: file,
        fingerprint: fingerprint
      )
      return .success(scan.filtered(to: range))
    case .cancelled:
      return .cancelled
    case .failure:
      return .failure
    }
  }

  private func aggregate(_ scans: [LocalUsageFileScan]) -> LocalUsageScanOutcome {
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
      guard !Task.isCancelled else { return nil }
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
  case cancelled
  case failure
}

struct LocalUsageScanResult: Sendable {
  let records: [LocalTokenRecord]
  let unsupportedUsage: [LocalUnsupportedUsage]
}

private enum LocalUsageFilesOutcome {
  case success([LocalUsageFileScan])
  case cancelled
  case failure
}

struct LocalUnsupportedUsage: Codable, Equatable, Sendable {
  let day: Date
  let model: String?
  let sessionID: String?
}

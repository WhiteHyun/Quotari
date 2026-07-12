import Foundation

public protocol UsageCostEstimating: Sendable {
  func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary?
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary?
  func invalidateCachedCostSummary(provider: UsageProvider, historyDays: Int)
  func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> CostSummary?
  func costSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> CostSummary?
  func invalidateCachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  )
}

public extension UsageCostEstimating {
  func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary? {
    nil
  }

  func invalidateCachedCostSummary(provider: UsageProvider, historyDays: Int) {}

  func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> CostSummary? {
    cachedCostSummary(provider: provider, now: now, historyDays: historyDays)
  }

  func costSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> CostSummary? {
    await costSummary(provider: provider, now: now, historyDays: historyDays)
  }

  func invalidateCachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  ) {
    invalidateCachedCostSummary(provider: provider, historyDays: historyDays)
  }
}

public struct LocalUsageCostEstimator: UsageCostEstimating {
  private let environment: [String: String]
  private let homeDirectory: URL
  private let cacheDirectory: URL
  private let pricingCatalogProvider: any ModelPricingCatalogProviding

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
      pricingCatalogProvider: RemoteModelPricingCatalogStore(cacheDirectory: pricingCacheDirectory)
    )
  }

  init(
    environment: [String: String],
    homeDirectory: URL,
    cacheDirectory: URL? = nil,
    pricingCatalogProvider: any ModelPricingCatalogProviding
  ) {
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.cacheDirectory = cacheDirectory ?? homeDirectory
      .appendingPathComponent("Library/Caches/Quotari/LocalUsageCost", isDirectory: true)
    self.pricingCatalogProvider = pricingCatalogProvider
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
    LocalUsageCostCache(cacheDirectory: cacheDirectory)
      .load(provider: provider, scopeID: account?.costCacheScopeID, now: now, historyDays: historyDays)
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
    let environment = environment
    let homeDirectory = homeDirectory
    let cacheDirectory = cacheDirectory
    let pricingCatalogProvider = pricingCatalogProvider
    let scan = await Task.detached(priority: .utility) {
      LocalUsageCostScanner(
        environment: environment,
        homeDirectory: homeDirectory
      ).scan(provider: provider, account: account, now: now, historyDays: historyDays)
    }.value
    let keys = Set(scan.records.compactMap { record in
      record.model.map { ModelPricingKey(provider: provider, modelID: $0) }
    })
    let pricingSnapshot = if keys.isEmpty {
      ModelPricingCatalogSnapshot.bundledOnly
    } else {
      await pricingCatalogProvider.snapshot(for: keys, now: now)
    }
    let summary = await Task.detached(priority: .utility) {
      LocalCostSummaryBuilder.summary(
        provider: provider,
        records: scan.records,
        range: scan.range,
        pricing: LocalModelPricing(snapshot: pricingSnapshot),
        sourceDescription: scan.sourceDescription
      )
    }.value
    if let summary {
      LocalUsageCostCache(cacheDirectory: cacheDirectory)
        .save(
          summary,
          provider: provider,
          scopeID: account?.costCacheScopeID,
          now: now,
          historyDays: historyDays
        )
    }
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
    LocalUsageCostCache(cacheDirectory: cacheDirectory)
      .remove(provider: provider, scopeID: account?.costCacheScopeID, historyDays: historyDays)
  }
}

struct LocalUsageCostScanner {
  private let environment: [String: String]
  private let homeDirectory: URL
  private let fileManager: FileManager
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
    let records: [LocalTokenRecord] = switch provider {
    case .codex:
      scanCodex(range: range, account: account)
    case .claude:
      scanClaude(range: range, account: account)
    }
    return LocalUsageScan(
      records: records,
      range: range,
      sourceDescription: sourceDescription(account: account)
    )
  }

  private func scanCodex(range: DayRange, account: ProviderAccount?) -> [LocalTokenRecord] {
    codexRoots(account: account).flatMap { root in
      jsonlFiles(in: root, modifiedSince: range.start).flatMap { parseCodexFile($0, range: range) }
    }
  }

  private func scanClaude(range: DayRange, account: ProviderAccount?) -> [LocalTokenRecord] {
    claudeProjectRoots(account: account).flatMap { root in
      jsonlFiles(in: root, modifiedSince: range.start).flatMap { parseClaudeFile($0, range: range) }
    }
  }

  private func codexRoots(account: ProviderAccount?) -> [URL] {
    if let account,
       case let .codexAuthFile(path) = account.credentialSource {
      return codexRoots(home: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    let home: URL = {
      if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
         !raw.isEmpty {
        return URL(fileURLWithPath: raw, isDirectory: true)
      }
      return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }()

    return codexRoots(home: home)
  }

  private func codexRoots(home: URL) -> [URL] {
    let roots = [
      home.appendingPathComponent("sessions", isDirectory: true),
      home.appendingPathComponent("archived_sessions", isDirectory: true),
    ]
    return roots.filter { fileManager.fileExists(atPath: $0.path) }
  }

  private func claudeProjectRoots(account: ProviderAccount?) -> [URL] {
    if let account,
       case let .claudeCredentialsFile(path) = account.credentialSource {
      let config = URL(fileURLWithPath: path).deletingLastPathComponent()
      let projects = config.appendingPathComponent("projects", isDirectory: true)
      return fileManager.fileExists(atPath: projects.path) ? [projects] : []
    }

    let roots: [URL] = if let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty {
      raw.split(separator: ",").map { part in
        let url = URL(fileURLWithPath: String(part).trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        return url.lastPathComponent == "projects" ? url : url.appendingPathComponent("projects", isDirectory: true)
      }
    } else {
      [
        homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true),
        homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
      ] + ClaudeDesktopProjectRoots.locate(homeDirectory: homeDirectory, fileManager: fileManager)
    }
    return deduplicated(roots).filter { fileManager.fileExists(atPath: $0.path) }
  }

  private func sourceDescription(account: ProviderAccount?) -> String? {
    guard let account else { return nil }
    return switch account.credentialSource {
    case .codexAuthFile:
      "Estimated from selected account's local Codex logs"
    case .claudeCredentialsFile:
      "Estimated from selected account's local Claude cache logs"
    case .claudeEnvironment, .claudeKeychain, .quotariRegistry:
      "Estimated from local Claude cache logs (not account-specific)"
    }
  }

  private func jsonlFiles(in root: URL, modifiedSince: Date) -> [URL] {
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsPackageDescendants]
    ) else { return [] }

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

  private func deduplicated(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for url in urls {
      let canonical = url.resolvingSymlinksInPath().standardizedFileURL
      guard seen.insert(canonical.path).inserted else { continue }
      result.append(canonical)
    }
    return result
  }
}

struct LocalUsageScan: Sendable {
  let records: [LocalTokenRecord]
  let range: DayRange
  let sourceDescription: String?
}

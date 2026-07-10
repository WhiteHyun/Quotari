import Foundation

protocol ModelPricingCatalogProviding: Sendable {
  func snapshot(for keys: Set<ModelPricingKey>, now: Date) async -> ModelPricingCatalogSnapshot
}

struct ModelPricingCatalogSnapshot: Sendable {
  static let bundledOnly = Self(remote: .empty, remoteIsStale: false)

  let remote: ModelPricingCatalog
  let remoteIsStale: Bool
}

struct BundledModelPricingCatalogProvider: ModelPricingCatalogProviding {
  func snapshot(for keys: Set<ModelPricingKey>, now: Date) async -> ModelPricingCatalogSnapshot {
    .bundledOnly
  }
}

actor RemoteModelPricingCatalogStore: ModelPricingCatalogProviding {
  static let defaultURL = URL(
    string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
  )!

  private let transport: any ProviderHTTPTransport
  private let sourceURL: URL
  private let cacheDirectory: URL
  private let refreshInterval: TimeInterval
  private let retryInterval: TimeInterval
  private let requestTimeout: TimeInterval
  private let maxResponseBytes: Int
  private let fileManager: FileManager

  private var cachedState: CacheState?
  private var didLoadDiskCache = false
  private var lastRefreshAttempt: Date?
  private var refreshTask: Task<Void, Never>?

  init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    sourceURL: URL = defaultURL,
    cacheDirectory: URL,
    refreshInterval: TimeInterval = 24 * 3600,
    retryInterval: TimeInterval = 3600,
    requestTimeout: TimeInterval = 8,
    maxResponseBytes: Int = 5 * 1024 * 1024,
    fileManager: FileManager = .default
  ) {
    self.transport = transport
    self.sourceURL = sourceURL
    self.cacheDirectory = cacheDirectory
    self.refreshInterval = refreshInterval
    self.retryInterval = retryInterval
    self.requestTimeout = requestTimeout
    self.maxResponseBytes = maxResponseBytes
    self.fileManager = fileManager
  }

  func snapshot(for keys: Set<ModelPricingKey>, now: Date) async -> ModelPricingCatalogSnapshot {
    loadDiskCacheIfNeeded()
    let stateBeforeRefresh = cachedState
    let hasUnknownModel = keys.contains { key in
      stateBeforeRefresh?.catalog.pricing(for: key) == nil
        && BundledModelPricingCatalog.pricing(for: key) == nil
    }
    let isDue = stateBeforeRefresh.map { now.timeIntervalSince($0.fetchedAt) >= refreshInterval } ?? true
    let canAttempt = lastRefreshAttempt.map { now.timeIntervalSince($0) >= retryInterval } ?? true

    if let refreshTask {
      await refreshTask.value
    } else if isDue || hasUnknownModel, canAttempt {
      await refresh(now: now)
    }

    guard let state = cachedState else { return .bundledOnly }
    return ModelPricingCatalogSnapshot(
      remote: state.catalog,
      remoteIsStale: now.timeIntervalSince(state.fetchedAt) >= refreshInterval
    )
  }

  private func refresh(now: Date) async {
    if let refreshTask {
      await refreshTask.value
      return
    }

    lastRefreshAttempt = now
    let etag = cachedState?.etag
    let transport = transport
    let sourceURL = sourceURL
    let requestTimeout = requestTimeout
    let maxResponseBytes = maxResponseBytes
    let task = Task { [self] in
      let result = try? await Self.fetch(
        transport: transport,
        sourceURL: sourceURL,
        etag: etag,
        requestTimeout: requestTimeout,
        maxResponseBytes: maxResponseBytes
      )
      if let result {
        apply(result, now: now)
      }
      refreshTask = nil
    }
    refreshTask = task
    await task.value
  }

  private func apply(_ result: FetchResult, now: Date) {
    switch result {
    case let .notModified(etag):
      guard let state = cachedState else { return }
      cachedState = CacheState(
        data: state.data,
        catalog: state.catalog,
        fetchedAt: now,
        etag: etag ?? state.etag
      )
      persistMetadata(fetchedAt: now, etag: etag ?? state.etag)
    case let .updated(data, catalog, etag):
      let state = CacheState(data: data, catalog: catalog, fetchedAt: now, etag: etag)
      cachedState = state
      persist(state)
    }
  }

  private func loadDiskCacheIfNeeded() {
    guard !didLoadDiskCache else { return }
    didLoadDiskCache = true
    guard let data = try? Data(contentsOf: catalogURL),
          data.count <= maxResponseBytes,
          let metadataData = try? Data(contentsOf: metadataURL),
          let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: metadataData),
          let parsed = try? LiteLLMPricingCatalogParser.parse(data),
          Self.isUsable(parsed.catalog)
    else { return }
    cachedState = CacheState(
      data: data,
      catalog: parsed.catalog,
      fetchedAt: metadata.fetchedAt,
      etag: metadata.etag
    )
  }

  private func persist(_ state: CacheState) {
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? state.data.write(to: catalogURL, options: [.atomic])
    persistMetadata(fetchedAt: state.fetchedAt, etag: state.etag)
  }

  private func persistMetadata(fetchedAt: Date, etag: String?) {
    let metadata = CacheMetadata(fetchedAt: fetchedAt, etag: etag)
    guard let data = try? JSONEncoder().encode(metadata) else { return }
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? data.write(to: metadataURL, options: [.atomic])
  }

  private var catalogURL: URL {
    cacheDirectory.appendingPathComponent("catalog.json", isDirectory: false)
  }

  private var metadataURL: URL {
    cacheDirectory.appendingPathComponent("metadata.json", isDirectory: false)
  }

  private static func fetch(
    transport: any ProviderHTTPTransport,
    sourceURL: URL,
    etag: String?,
    requestTimeout: TimeInterval,
    maxResponseBytes: Int
  ) async throws -> FetchResult {
    var request = URLRequest(url: sourceURL, timeoutInterval: requestTimeout)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let etag {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    let (data, response) = try await transport.data(for: request)
    let responseETag = response.value(forHTTPHeaderField: "ETag")
    if response.statusCode == 304 {
      return .notModified(etag: responseETag)
    }
    guard 200 ..< 300 ~= response.statusCode else {
      throw ProviderHTTPError.status(response.statusCode)
    }
    guard data.count <= maxResponseBytes else {
      throw PricingCatalogStoreError.responseTooLarge
    }
    let parsed = try LiteLLMPricingCatalogParser.parse(data)
    guard isUsable(parsed.catalog) else {
      throw PricingCatalogStoreError.incompleteCatalog
    }
    return .updated(data: data, catalog: parsed.catalog, etag: responseETag)
  }

  private static func isUsable(_ catalog: ModelPricingCatalog) -> Bool {
    !catalog.isEmpty && catalog.contains(provider: .codex) && catalog.contains(provider: .claude)
  }
}

private extension RemoteModelPricingCatalogStore {
  struct CacheState: Sendable {
    let data: Data
    let catalog: ModelPricingCatalog
    let fetchedAt: Date
    let etag: String?
  }

  struct CacheMetadata: Codable {
    let fetchedAt: Date
    let etag: String?
  }

  enum FetchResult: Sendable {
    case notModified(etag: String?)
    case updated(data: Data, catalog: ModelPricingCatalog, etag: String?)
  }
}

private enum PricingCatalogStoreError: Error {
  case responseTooLarge
  case incompleteCatalog
}

import CryptoKit
import Foundation
import os

public struct CredentialLifecycleEvent: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public enum Kind: String, Codable, Sendable {
    case monitoringPass
    case validationStarted
    case validationSucceeded
    case validationFailed
    case pendingGrantFound
    case pendingGrantReadFailed
    case refreshSelected
    case refreshStarted
    case refreshSucceeded
    case refreshFailed
    case persistenceSucceeded
    case persistenceDeferred
    case persistenceFailed
    case switchStarted
    case switchCredentialsWritten
    case switchVerified
    case switchFailed
    case postSwitchRefreshScheduled
    case postSwitchRefreshStarted
    case postSwitchRefreshCompleted
    case postSwitchRefreshCancelled
  }

  public enum Source: String, Codable, Sendable {
    case codexFile
    case codexKeychain
    case claudeEnvironment
    case claudeKeychain
    case claudeFile
    case quotariRegistry

    init(_ source: ProviderCredentialSource) {
      self = switch source {
      case .codexAuthFile: .codexFile
      case .codexKeychain: .codexKeychain
      case .claudeEnvironment: .claudeEnvironment
      case .claudeKeychain: .claudeKeychain
      case .claudeCredentialsFile: .claudeFile
      case .quotariRegistry: .quotariRegistry
      }
    }
  }

  public enum Interaction: String, Codable, Sendable {
    case background
    case userInitiated

    init(_ interaction: ProviderFetchInteraction) {
      self = switch interaction {
      case .background: .background
      case .userInitiated: .userInitiated
      }
    }
  }

  public enum Reason: String, Codable, Sendable {
    case expired
    case unauthorized
    case pendingGrant
    case scheduled
    case forced
    case delayedAfterSwitch
    case immediateAfterSwitch
    case concurrentCredentialChange
  }

  public enum Failure: String, Codable, Sendable {
    case reauthenticationRequired
    case unauthorized
    case rateLimited
    case credentialUnavailable
    case cancelled
    case staleSource
    case persistence
    case cliActive
    case concurrentCredentialChange
    case verification
    case malformedResponse
    case inputOutput
    case unknown
  }

  public let schemaVersion: Int
  public let timestamp: Date
  public let provider: UsageProvider
  public let kind: Kind
  public let source: Source?
  /// An installation-salted digest. Never an email, provider account ID,
  /// registry ID, filesystem path, keychain label, or credential fingerprint.
  public let accountID: String?
  public let interaction: Interaction?
  public let reason: Reason?
  public let failure: Failure?
  public let monitoredAccountCount: Int?
  public let eligibleAccountCount: Int?

  init(
    timestamp: Date,
    provider: UsageProvider,
    kind: Kind,
    source: Source? = nil,
    accountID: String? = nil,
    interaction: Interaction? = nil,
    reason: Reason? = nil,
    failure: Failure? = nil,
    monitoredAccountCount: Int? = nil,
    eligibleAccountCount: Int? = nil
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.timestamp = timestamp
    self.provider = provider
    self.kind = kind
    self.source = source
    self.accountID = accountID
    self.interaction = interaction
    self.reason = reason
    self.failure = failure
    self.monitoredAccountCount = monitoredAccountCount
    self.eligibleAccountCount = eligibleAccountCount
  }
}

public struct CredentialLifecycleLogger: Sendable {
  private static let osLogger = Logger(
    subsystem: "com.quotari.QuotariCore",
    category: "credential-lifecycle"
  )

  public static let shared: Self = {
    let store = CredentialLifecycleLogStore()
    let runtime = CredentialLifecycleLogRuntime(store: store)
    return Self(
      record: { event in
        let provider = event.provider.rawValue
        let kind = event.kind.rawValue
        osLogger.info(
          "Credential lifecycle event provider=\(provider, privacy: .public) kind=\(kind, privacy: .public)"
        )
        runtime.record(event)
      },
      opaqueAccountID: { rawIdentifier in
        store.opaqueIdentifier(for: rawIdentifier)
      },
      prepareLogForAccess: {
        await runtime.prepareLogForAccess()
      }
    )
  }()

  public static let disabled = Self(record: { _ in })

  private let recordValue: @Sendable (CredentialLifecycleEvent) -> Void
  private let opaqueAccountIDValue: @Sendable (String) -> String
  private let nowValue: @Sendable () -> Date
  private let prepareLogForAccessValue: @Sendable () async -> URL

  init(
    record: @escaping @Sendable (CredentialLifecycleEvent) -> Void,
    opaqueAccountID: @escaping @Sendable (String) -> String = { _ in "test-account" },
    now: @escaping @Sendable () -> Date = Date.init,
    prepareLogForAccess: @escaping @Sendable () async -> URL = {
      CredentialLifecycleLogStore.defaultURL()
    }
  ) {
    recordValue = record
    opaqueAccountIDValue = opaqueAccountID
    nowValue = now
    prepareLogForAccessValue = prepareLogForAccess
  }

  public func record(
    _ kind: CredentialLifecycleEvent.Kind,
    provider: UsageProvider,
    account: ProviderAccount? = nil,
    source: ProviderCredentialSource? = nil,
    correlationSource: ProviderCredentialSource? = nil,
    interaction: ProviderFetchInteraction? = nil,
    reason: CredentialLifecycleEvent.Reason? = nil,
    failure: CredentialLifecycleEvent.Failure? = nil,
    monitoredAccountCount: Int? = nil,
    eligibleAccountCount: Int? = nil,
    timestamp: Date? = nil
  ) {
    let resolvedSource = source ?? account?.credentialSource
    let rawIdentifier = account?.id ?? (correlationSource ?? resolvedSource).map {
      ProviderAccount.id(provider: provider, source: $0)
    }
    recordValue(CredentialLifecycleEvent(
      timestamp: timestamp ?? nowValue(),
      provider: provider,
      kind: kind,
      source: resolvedSource.map(CredentialLifecycleEvent.Source.init),
      accountID: rawIdentifier.map(opaqueAccountIDValue),
      interaction: interaction.map(CredentialLifecycleEvent.Interaction.init),
      reason: reason,
      failure: failure,
      monitoredAccountCount: monitoredAccountCount,
      eligibleAccountCount: eligibleAccountCount
    ))
  }

  public func prepareLogForAccess() async -> URL {
    await prepareLogForAccessValue()
  }
}

public final class CredentialLifecycleLogStore: @unchecked Sendable {
  public static let defaultRetention: TimeInterval = 21 * 24 * 60 * 60
  public static let defaultMaximumByteCount = 5 * 1024 * 1024

  public let url: URL
  public let saltURL: URL

  private let retention: TimeInterval
  private let maximumByteCount: Int
  let compactionTargetByteCount: Int
  private let now: @Sendable () -> Date
  private let fileManager: FileManager
  private let injectedSalt: Data?
  private let fallbackSalt = Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
  private let lock = NSLock()
  private var cachedSalt: Data?
  private var lastCompactionAt: Date?

  init(
    url: URL = CredentialLifecycleLogStore.defaultURL(),
    retention: TimeInterval = CredentialLifecycleLogStore.defaultRetention,
    maximumByteCount: Int = CredentialLifecycleLogStore.defaultMaximumByteCount,
    now: @escaping @Sendable () -> Date = Date.init,
    fileManager: FileManager = .default,
    identitySalt: Data? = nil
  ) {
    precondition(retention > 0)
    precondition(maximumByteCount > 0)
    self.url = url
    saltURL = url.deletingPathExtension().appendingPathExtension("salt")
    self.retention = retention
    self.maximumByteCount = maximumByteCount
    compactionTargetByteCount = max(1, maximumByteCount * 4 / 5)
    self.now = now
    self.fileManager = fileManager
    injectedSalt = identitySalt
  }

  public static func defaultURL(
    fileManager: FileManager = .default
  ) -> URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return base
      .appendingPathComponent("Quotari/Diagnostics", isDirectory: true)
      .appendingPathComponent("CredentialLifecycle.jsonl")
  }

  func opaqueIdentifier(for rawIdentifier: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    var input = resolvedSalt()
    input.append(contentsOf: rawIdentifier.utf8)
    return SHA256.hash(data: input)
      .prefix(16)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  func record(_ event: CredentialLifecycleEvent) throws {
    lock.lock()
    defer { lock.unlock() }
    try materializeLogFile()
    let line = try Self.makeEncoder().encode(event) + Data([0x0A])
    try Self.appendCompleteLine(line, to: url)

    let current = now()
    let fileSize = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    let compactionDue = lastCompactionAt.map { current.timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
    let exceedsMaximum = (fileSize?.intValue ?? 0) > maximumByteCount
    if exceedsMaximum || compactionDue {
      try compact(
        at: current,
        targetByteCount: exceedsMaximum ? compactionTargetByteCount : maximumByteCount
      )
      lastCompactionAt = current
    }
  }

  func performMaintenance() throws {
    lock.lock()
    defer { lock.unlock() }
    guard fileManager.fileExists(atPath: url.path) else { return }
    try maintainExistingLog()
  }

  func prepareLogForAccess() throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    try materializeLogFile()
    try applyOwnerOnlyPermissions(to: url, directory: false)
    try maintainExistingLog()
    return url
  }

  private func maintainExistingLog() throws {
    let fileSize = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    let exceedsMaximum = (fileSize?.intValue ?? 0) > maximumByteCount
    let current = now()
    try compact(
      at: current,
      targetByteCount: exceedsMaximum ? compactionTargetByteCount : maximumByteCount
    )
    lastCompactionAt = current
  }

  func events() throws -> [CredentialLifecycleEvent] {
    lock.lock()
    defer { lock.unlock() }
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    return try Self.decodeLines(Data(contentsOf: url))
  }

  private func resolvedSalt() -> Data {
    if let cachedSalt {
      return cachedSalt
    }
    if let injectedSalt {
      cachedSalt = injectedSalt
      return injectedSalt
    }
    if let stored = try? Data(contentsOf: saltURL), !stored.isEmpty {
      cachedSalt = stored
      return stored
    }
    let generated = Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
    do {
      try ensureDirectory()
      try generated.write(to: saltURL, options: .atomic)
      try applyOwnerOnlyPermissions(to: saltURL, directory: false)
      cachedSalt = generated
      return generated
    } catch {
      cachedSalt = fallbackSalt
      return fallbackSalt
    }
  }

  private func compact(at current: Date, targetByteCount: Int) throws {
    let cutoff = current.addingTimeInterval(-retention)
    let encoder = Self.makeEncoder()
    var lines = try Self.decodeLines(Data(contentsOf: url))
      .filter { $0.timestamp >= cutoff }
      .map { try encoder.encode($0) + Data([0x0A]) }
    var byteCount = lines.reduce(0) { $0 + $1.count }
    while byteCount > targetByteCount, !lines.isEmpty {
      byteCount -= lines.removeFirst().count
    }
    var compacted = Data(capacity: byteCount)
    for line in lines {
      compacted.append(line)
    }
    try compacted.write(to: url, options: .atomic)
    try applyOwnerOnlyPermissions(to: url, directory: false)
  }

  private func ensureDirectory() throws {
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try applyOwnerOnlyPermissions(to: directory, directory: true)
  }

  private func materializeLogFile() throws {
    try ensureDirectory()
    guard !fileManager.fileExists(atPath: url.path) else { return }
    try Data().write(to: url, options: .atomic)
    try applyOwnerOnlyPermissions(to: url, directory: false)
  }

  private func applyOwnerOnlyPermissions(to target: URL, directory: Bool) throws {
    try fileManager.setAttributes(
      [.posixPermissions: directory ? 0o700 : 0o600],
      ofItemAtPath: target.path
    )
  }
}

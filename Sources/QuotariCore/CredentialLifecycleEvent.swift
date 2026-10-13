import Foundation

public struct CredentialLifecycleEvent: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public enum Kind: String, Codable, Sendable {
    case credentialObserved
    case tokenEndpointResponded
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
    case automaticCLIRecoverySucceeded
    case automaticCLIRecoveryFailed
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

  public let diagnostic: CredentialLifecycleDiagnostic?
  public let sessionID: UUID?
  public let appVersion: String?
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
    eligibleAccountCount: Int? = nil,
    diagnostic: CredentialLifecycleDiagnostic? = nil,
    sessionID: UUID? = nil,
    appVersion: String? = nil
  ) {
    self.diagnostic = diagnostic
    self.sessionID = sessionID
    self.appVersion = appVersion
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

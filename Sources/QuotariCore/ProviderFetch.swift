import Foundation

public enum ProviderFetchKind: String, Sendable {
  case api, oauth, web, cli
}

public enum ProviderFetchInteraction: Sendable {
  case background
  case userInitiated
}

public struct ProviderFetchContext: Sendable {
  public let provider: UsageProvider
  public let now: Date
  public let credential: String?
  public let account: ProviderAccount?
  /// User actions can explicitly retry a provider while an automatic
  /// rate-limit cooldown is active. Timer and account maintenance fetches
  /// remain background work and respect that cooldown.
  public let interaction: ProviderFetchInteraction
  /// Saved registry row proven equivalent to the live account at discovery
  /// time. Claude refresh uses this explicit id to mirror a rotated grant
  /// without deriving identity from the newly-rotated refresh token.
  public let capturedRegistryID: String?

  public init(
    provider: UsageProvider,
    now: Date,
    credential: String? = nil,
    account: ProviderAccount? = nil,
    capturedRegistryID: String? = nil,
    interaction: ProviderFetchInteraction = .background
  ) {
    self.provider = provider
    self.now = now
    self.credential = credential
    self.account = account
    self.capturedRegistryID = capturedRegistryID
    self.interaction = interaction
  }
}

public struct ProviderFetchResult: Sendable {
  public let usage: UsageSnapshot
  public let sourceLabel: String
  public let sourceKind: ProviderFetchKind?
  /// Privacy-safe identity of the credential that produced this result.
  /// Accountless consumers can compare it with a later discovery before
  /// attributing the result to a mutable CLI slot.
  public let credentialScopeID: String?
  /// The credential generation installed by an OAuth transaction in this
  /// fetch. This remains separate from `credentialScopeID`: a later fallback
  /// can produce usage without using that credential, while the already-
  /// persisted transition still has to be reconciled by account discovery.
  public let credentialTransitionTargetScopeID: String?
  /// Credential generations that an OAuth transaction in this fetch
  /// explicitly advanced to `credentialTransitionTargetScopeID`. Merely
  /// observing that a mutable CLI slot changed is not transition proof: an
  /// external login can replace the slot while the request is in flight.
  public let credentialTransitionSourceScopeIDs: Set<String>

  public init(
    usage: UsageSnapshot,
    sourceLabel: String,
    sourceKind: ProviderFetchKind? = nil,
    credentialScopeID: String? = nil,
    credentialTransitionTargetScopeID: String? = nil,
    credentialTransitionSourceScopeIDs: Set<String> = []
  ) {
    self.usage = usage
    self.sourceLabel = sourceLabel
    self.sourceKind = sourceKind
    self.credentialScopeID = credentialScopeID
    self.credentialTransitionTargetScopeID = credentialTransitionTargetScopeID
      ?? (credentialTransitionSourceScopeIDs.isEmpty ? nil : credentialScopeID)
    self.credentialTransitionSourceScopeIDs = credentialTransitionSourceScopeIDs
  }

  func withSourceKind(_ kind: ProviderFetchKind) -> ProviderFetchResult {
    ProviderFetchResult(
      usage: usage,
      sourceLabel: sourceLabel,
      sourceKind: sourceKind ?? kind,
      credentialScopeID: credentialScopeID,
      credentialTransitionTargetScopeID: credentialTransitionTargetScopeID,
      credentialTransitionSourceScopeIDs: credentialTransitionSourceScopeIDs
    )
  }

  func mergingCredentialTransition(
    targetScopeID: String?,
    sourceScopeIDs: Set<String>
  ) -> ProviderFetchResult {
    guard let targetScopeID, !sourceScopeIDs.isEmpty else { return self }
    if let currentTarget = credentialTransitionTargetScopeID {
      if currentTarget == targetScopeID {
        return ProviderFetchResult(
          usage: usage,
          sourceLabel: sourceLabel,
          sourceKind: sourceKind,
          credentialScopeID: credentialScopeID,
          credentialTransitionTargetScopeID: currentTarget,
          credentialTransitionSourceScopeIDs: credentialTransitionSourceScopeIDs.union(sourceScopeIDs)
        )
      }
      guard credentialTransitionSourceScopeIDs.contains(targetScopeID) else {
        // Conflicting transition chains are not safe identity evidence. Keep
        // only the result's own proof; dropping an earlier link can lose an
        // anchor, but can never transfer it to an unrelated login.
        return self
      }
      // The result is the later B -> C leg and the accumulated evidence is
      // A -> B. Preserve the transitive A -> C lineage.
      return ProviderFetchResult(
        usage: usage,
        sourceLabel: sourceLabel,
        sourceKind: sourceKind,
        credentialScopeID: credentialScopeID,
        credentialTransitionTargetScopeID: currentTarget,
        credentialTransitionSourceScopeIDs: credentialTransitionSourceScopeIDs.union(sourceScopeIDs)
      )
    }
    return ProviderFetchResult(
      usage: usage,
      sourceLabel: sourceLabel,
      sourceKind: sourceKind,
      credentialScopeID: credentialScopeID,
      credentialTransitionTargetScopeID: targetScopeID,
      credentialTransitionSourceScopeIDs: credentialTransitionSourceScopeIDs.union(sourceScopeIDs)
    )
  }
}

/// Carries a credential transition that completed before a later part of the
/// provider request failed. The underlying failure remains authoritative for
/// fallback and UI error behavior; the transition is side-effect evidence for
/// account reconciliation only.
public struct ProviderFetchTransitionError: LocalizedError, @unchecked Sendable {
  public let underlying: any Error
  public let credentialTransitionTargetScopeID: String
  public let credentialTransitionSourceScopeIDs: Set<String>

  public init(
    underlying: any Error,
    credentialTransitionTargetScopeID: String,
    credentialTransitionSourceScopeIDs: Set<String>
  ) {
    self.underlying = underlying
    self.credentialTransitionTargetScopeID = credentialTransitionTargetScopeID
    self.credentialTransitionSourceScopeIDs = credentialTransitionSourceScopeIDs
  }

  public var errorDescription: String? {
    underlying.localizedDescription
  }
}

public enum ProviderFetchError: LocalizedError, Sendable {
  case noStrategyAvailable(UsageProvider)
  case missingCredential(UsageProvider)
  case selectedCredentialUnavailable(UsageProvider)
  case emptyUsage(UsageProvider)

  public var errorDescription: String? {
    let name: String = switch self {
    case let .noStrategyAvailable(provider),
         let .missingCredential(provider),
         let .selectedCredentialUnavailable(provider),
         let .emptyUsage(provider):
      provider.rawValue.capitalized
    }
    return switch self {
    case .noStrategyAvailable: "No live usage source is available for \(name)."
    case .missingCredential: "No \(name) account credential was found."
    case let .selectedCredentialUnavailable(p):
      "The selected \(p.rawValue.capitalized) account credential is missing or invalid."
    case .emptyUsage: "\(name) returned no usage windows."
    }
  }
}

/// One data source: availability check, fetch, and whether to fall back on error.
public protocol ProviderFetchStrategy: Sendable {
  var id: String { get }
  var kind: ProviderFetchKind { get }
  func isAvailable(_ context: ProviderFetchContext) async -> Bool
  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult
  func shouldFallback(on error: Error) -> Bool
}

public extension ProviderFetchStrategy {
  func isAvailable(_ context: ProviderFetchContext) async -> Bool {
    true
  }

  func shouldFallback(on error: Error) -> Bool {
    true
  }
}

/// Tries strategies in order; first available success wins, else falls back.
public struct ProviderFetchPipeline: Sendable {
  public let resolveStrategies: @Sendable (ProviderFetchContext) -> [any ProviderFetchStrategy]

  public init(resolveStrategies: @escaping @Sendable (ProviderFetchContext) -> [any ProviderFetchStrategy]) {
    self.resolveStrategies = resolveStrategies
  }

  public func fetch(_ context: ProviderFetchContext) async -> Result<ProviderFetchResult, Error> {
    var lastError: Error?
    var transitions = ProviderCredentialTransitionAccumulator()
    let strategies = resolveStrategies(context)
    var foundAvailableStrategy = false
    for strategy in strategies {
      if Task.isCancelled {
        return .failure(transitions.wrapping(CancellationError()))
      }
      guard await strategy.isAvailable(context) else { continue }
      foundAvailableStrategy = true
      do {
        let result = try await strategy.fetch(context)
          .withSourceKind(strategy.kind)
          .mergingCredentialTransition(
            targetScopeID: transitions.targetScopeID,
            sourceScopeIDs: transitions.sourceScopeIDs
          )
        return .success(result)
      } catch {
        if error is CancellationError {
          return .failure(transitions.wrapping(error))
        }
        let underlying = transitions.record(error)
        if underlying is CancellationError {
          return .failure(transitions.wrapping(underlying))
        }
        lastError = underlying
        if strategy.shouldFallback(on: underlying) {
          continue
        }
        return .failure(transitions.wrapping(underlying))
      }
    }
    let error = lastError
      ?? (strategies.isEmpty || foundAvailableStrategy
        ? ProviderFetchError.noStrategyAvailable(context.provider)
        : ProviderFetchError.missingCredential(context.provider))
    return .failure(transitions.wrapping(error))
  }
}

private struct ProviderCredentialTransitionAccumulator {
  private(set) var targetScopeID: String?
  private(set) var sourceScopeIDs = Set<String>()
  private var isConflicting = false

  mutating func record(_ error: any Error) -> any Error {
    guard let transition = error as? ProviderFetchTransitionError else { return error }
    defer { merge(transition) }
    return transition.underlying
  }

  func wrapping(_ error: any Error) -> any Error {
    guard let targetScopeID, !sourceScopeIDs.isEmpty else { return error }
    return ProviderFetchTransitionError(
      underlying: error,
      credentialTransitionTargetScopeID: targetScopeID,
      credentialTransitionSourceScopeIDs: sourceScopeIDs
    )
  }

  private mutating func merge(_ transition: ProviderFetchTransitionError) {
    guard !isConflicting else { return }
    if targetScopeID == nil || targetScopeID == transition.credentialTransitionTargetScopeID {
      targetScopeID = transition.credentialTransitionTargetScopeID
      sourceScopeIDs.formUnion(transition.credentialTransitionSourceScopeIDs)
    } else if let targetScopeID,
              transition.credentialTransitionSourceScopeIDs.contains(targetScopeID) {
      self.targetScopeID = transition.credentialTransitionTargetScopeID
      sourceScopeIDs.formUnion(transition.credentialTransitionSourceScopeIDs)
    } else {
      isConflicting = true
      targetScopeID = nil
      sourceScopeIDs.removeAll()
    }
  }
}

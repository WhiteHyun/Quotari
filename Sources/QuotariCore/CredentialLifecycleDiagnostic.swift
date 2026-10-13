import Foundation

/// Only installation-keyed digests and bounded metadata cross into the log.
public struct CredentialLifecycleGeneration: Codable, Equatable, Sendable {
  public let access: String?
  public let refresh: String?
  public let expiresAt: Date?
}

public struct CredentialLifecycleDiagnostic: Codable, Equatable, Sendable {
  public var operationID: UUID?
  public var generation: CredentialLifecycleGeneration?
  public var receivedGeneration: CredentialLifecycleGeneration?
  public var storedGeneration: CredentialLifecycleGeneration?
  public var storageReadFailed: Bool?
  public var sourceID: String?
  public var httpStatus: Int?
  public var oauthError: OAuthError?

  public enum OAuthError: String, Codable, Sendable {
    case invalidGrant = "invalid_grant"
    case invalidClient = "invalid_client"
    case invalidRequest = "invalid_request"
    case invalidScope = "invalid_scope"
    case unauthorizedClient = "unauthorized_client"
    case unsupportedGrantType = "unsupported_grant_type"
    case other
  }
}

extension CredentialLifecycleLogger {
  func generation(_ credentials: ClaudeCredentials) -> CredentialLifecycleGeneration {
    CredentialLifecycleGeneration(
      access: tokenFingerprintValue(credentials.accessToken),
      refresh: credentials.refreshToken.flatMap(tokenFingerprintValue),
      expiresAt: credentials.expiresAt
    )
  }

  func observe(_ credentials: ClaudeCredentials, source: ProviderCredentialSource) {
    record(
      .credentialObserved, provider: .claude, source: source,
      diagnostic: CredentialLifecycleDiagnostic(generation: generation(credentials))
    )
  }
}

/// Keeps endpoint metadata on the same exchange ID without changing auth errors.
struct ClaudeRefreshDiagnosticContext: Sendable {
  @TaskLocal static var current: ClaudeRefreshDiagnosticContext?
  let report: @Sendable (Int, CredentialLifecycleDiagnostic.OAuthError?) -> Void
}

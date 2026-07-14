@testable import QuotariCore
import Testing

func expectClaudeMirrorRecoveryFailure(_ operation: () throws -> Void) {
  do {
    try operation()
    Issue.record("expected mirrorRecoveryPending")
  } catch let error as ClaudeCredentialPersistError {
    guard case .mirrorRecoveryPending = error else {
      Issue.record("expected mirrorRecoveryPending, got \(error)")
      return
    }
  } catch {
    Issue.record("expected ClaudeCredentialPersistError, got \(error)")
  }
}

func expectClaudeMirrorRecoveryFailure(
  _ writer: ClaudeCredentialsWriter,
  _ grant: ClaudeTokenGrant,
  replacing previousAccessToken: String
) {
  expectClaudeMirrorRecoveryFailure {
    try writer.persist(
      grant,
      replacing: previousAccessToken,
      to: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )
  }
}

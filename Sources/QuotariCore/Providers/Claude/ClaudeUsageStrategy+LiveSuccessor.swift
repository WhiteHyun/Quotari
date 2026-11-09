import Foundation

extension ClaudeUsageStrategy {
  /// The CLI slots whose recovery records a saved copy may inherit from.
  public static func defaultLiveSuccessorSources(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [ProviderCredentialSource] {
    [
      .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      .claudeCredentialsFile(
        path: home.appendingPathComponent(".claude/.credentials.json").standardizedFileURL.path
      ),
    ]
  }

  /// A saved copy shares its token pair with the live CLI slot it was
  /// captured from. When Quotari exchanged that pair on the slot's behalf but
  /// neither the slot nor the copy accepted the write (a locked keychain
  /// during sleep, for example), the copy is left on the consumed refresh
  /// token and every later exchange answers `invalid_grant`.
  ///
  /// The slot's recovery record carries the issued grant together with the
  /// exact pair it replaced, so that lineage — not a guess from account
  /// identity — proves the grant is this copy's successor. The record itself
  /// is left in place: the CLI slot still needs it.
  ///
  /// Returns true when the saved copy now holds the successor grant.
  func adoptLiveSuccessorGrant(
    registryID id: String,
    stored: ClaudeCredentials,
    now: Date
  ) async -> Bool {
    guard stored.refreshToken != nil else { return false }
    for source in liveSuccessorSources {
      var candidates: [ClaudePendingGrant] = []
      if let queued = await refreshCoordinator.peekUnpersisted(sourceID: source.stableID) {
        candidates.append(queued)
      }
      if let durable = try? loadDurablePending(source: source), !candidates.contains(durable) {
        candidates.append(durable)
      }
      for pending in candidates where pending.rotatedRefreshToken
        && pending.supersedes(accessToken: stored.accessToken, refreshToken: stored.refreshToken) {
        do {
          try ClaudeCredentialsWriter(capturedAccounts: capturedAccounts).persist(
            pending.grant,
            replacing: stored.accessToken,
            to: .quotariRegistry(id: id)
          )
        } catch {
          Self.logger.error(
            "Adopting a live successor grant failed: \(error.localizedDescription, privacy: .public)"
          )
          continue
        }
        recordLifecycle(
          .persistenceSucceeded,
          source: .quotariRegistry(id: id),
          correlationSource: source,
          reason: .pendingGrant,
          timestamp: now,
          diagnostic: CredentialLifecycleDiagnostic(
            operationID: UUID(),
            generation: credentialLifecycleLogger.generation(stored),
            receivedGeneration: credentialLifecycleLogger.generation(
              inMemory(
                ResolvedClaudeCredentials(credentials: stored, source: .quotariRegistry(id: id)),
                pending.grant
              ).credentials
            )
          )
        )
        return true
      }
    }
    return false
  }
}

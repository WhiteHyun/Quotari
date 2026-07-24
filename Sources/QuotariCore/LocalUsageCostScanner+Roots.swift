import Foundation

extension LocalUsageCostScanner {
  func configuredRoots(provider: UsageProvider, account: ProviderAccount?) -> [URL] {
    switch provider {
    case .codex:
      codexRoots(account: account, resolvesSymlinks: true)
    case .claude:
      claudeProjectRoots(account: account, resolvesSymlinks: true)
    }
  }

  func scopeRoots(provider: UsageProvider, account: ProviderAccount?) -> [URL] {
    let configured = sharedConfiguredRoots(provider: provider, account: account)
    let existing = configured.filter { fileManager.fileExists(atPath: $0.path) }
    return existing.isEmpty ? configured : existing
  }

  func observationRoots(provider: UsageProvider, account: ProviderAccount?) -> [URL] {
    let configured = configuredRoots(provider: provider, account: account)
    guard provider == .claude,
          usesAutomaticRootFamily(provider: provider, account: account),
          environment["CLAUDE_CONFIG_DIR"]?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty != false
    else {
      return configured
    }

    return normalized(
      configured + ClaudeDesktopProjectRoots.sessionRoots(homeDirectory: homeDirectory),
      resolvesSymlinks: true
    )
  }

  func scopeIdentityRoots(provider: UsageProvider, account: ProviderAccount?) -> [URL] {
    guard provider == .claude,
          usesAutomaticRootFamily(provider: provider, account: account),
          environment["CLAUDE_CONFIG_DIR"]?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty != false
    else {
      return sharedConfiguredIdentityRoots(provider: provider, account: account)
    }

    return identityNormalized([
      homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true),
      homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
    ] + ClaudeDesktopProjectRoots.sessionRoots(homeDirectory: homeDirectory))
  }

  func sourceDescription(provider: UsageProvider, account: ProviderAccount?) -> String? {
    guard let account else {
      return provider == .codex
        ? "Estimated from local Codex logs (not account-specific)"
        : "Estimated from local Claude cache logs (not account-specific)"
    }
    return switch account.credentialSource {
    case .codexAuthFile, .codexKeychain:
      "Estimated from local Codex logs (not account-specific)"
    case .claudeCredentialsFile:
      "Estimated from local Claude cache logs (not account-specific)"
    case .claudeEnvironment, .claudeKeychain:
      "Estimated from local Claude cache logs (not account-specific)"
    case .quotariRegistry:
      account.provider == .codex
        ? "Saved account — local Codex cost estimate unavailable"
        : "Saved account — local Claude cost estimate unavailable"
    }
  }

  private func configuredIdentityRoots(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> [URL] {
    switch provider {
    case .codex:
      codexRoots(account: account, resolvesSymlinks: false)
    case .claude:
      claudeProjectRoots(account: account, resolvesSymlinks: false)
    }
  }

  private func sharedConfiguredIdentityRoots(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> [URL] {
    guard usesAutomaticRootFamily(provider: provider, account: account) else {
      return configuredIdentityRoots(provider: provider, account: account)
    }
    return configuredIdentityRoots(provider: provider, account: nil)
  }

  private func sharedConfiguredRoots(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> [URL] {
    let requested = configuredRoots(provider: provider, account: account)
    guard usesAutomaticRootFamily(provider: provider, account: account) else {
      return requested
    }
    return configuredRoots(provider: provider, account: nil)
  }

  private func usesAutomaticRootFamily(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> Bool {
    guard account != nil else { return true }
    let requested = Set(configuredRoots(provider: provider, account: account).map(\.path))
    let automatic = Set(configuredRoots(provider: provider, account: nil).map(\.path))
    return !requested.isDisjoint(with: automatic)
  }

  private func codexRoots(
    account: ProviderAccount?,
    resolvesSymlinks: Bool
  ) -> [URL] {
    if let account, account.credentialSource.isCaptured {
      return []
    }
    if let account,
       case let .codexAuthFile(path) = account.credentialSource {
      return codexRoots(
        home: URL(fileURLWithPath: path).deletingLastPathComponent(),
        resolvesSymlinks: resolvesSymlinks
      )
    }

    let home: URL = {
      if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
         !raw.isEmpty {
        return URL(fileURLWithPath: raw, isDirectory: true)
      }
      return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }()

    return codexRoots(home: home, resolvesSymlinks: resolvesSymlinks)
  }

  private func codexRoots(home: URL, resolvesSymlinks: Bool) -> [URL] {
    let home = normalized(home, resolvesSymlinks: resolvesSymlinks)
    return normalized([
      home.appendingPathComponent("sessions", isDirectory: true),
      home.appendingPathComponent("archived_sessions", isDirectory: true),
    ], resolvesSymlinks: resolvesSymlinks)
  }

  private func claudeProjectRoots(
    account: ProviderAccount?,
    resolvesSymlinks: Bool
  ) -> [URL] {
    if let account, account.credentialSource.isCaptured {
      return []
    }
    if let account,
       case let .claudeCredentialsFile(path) = account.credentialSource {
      let config = normalized(
        URL(fileURLWithPath: path).deletingLastPathComponent(),
        resolvesSymlinks: resolvesSymlinks
      )
      let projects = config.appendingPathComponent("projects", isDirectory: true)
      return normalized([projects], resolvesSymlinks: resolvesSymlinks)
    }

    let roots: [URL] = if let raw = environment["CLAUDE_CONFIG_DIR"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty {
      raw.split(separator: ",").map { part in
        let url = URL(
          fileURLWithPath: String(part).trimmingCharacters(in: .whitespacesAndNewlines),
          isDirectory: true
        )
        if url.lastPathComponent == "projects" {
          return url
        }
        return normalized(url, resolvesSymlinks: resolvesSymlinks)
          .appendingPathComponent("projects", isDirectory: true)
      }
    } else {
      [
        homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true),
        homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
      ] + ClaudeDesktopProjectRoots.locate(homeDirectory: homeDirectory, fileManager: fileManager)
    }
    return normalized(roots, resolvesSymlinks: resolvesSymlinks)
  }

  private func identityNormalized(_ urls: [URL]) -> [URL] {
    normalized(urls, resolvesSymlinks: false)
  }

  private func normalized(
    _ urls: [URL],
    resolvesSymlinks: Bool
  ) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for url in urls {
      let canonical = normalized(url, resolvesSymlinks: resolvesSymlinks)
      guard seen.insert(canonical.path).inserted else { continue }
      result.append(canonical)
    }
    return result.sorted { $0.path < $1.path }
  }

  private func normalized(_ url: URL, resolvesSymlinks: Bool) -> URL {
    let standardized = url.standardizedFileURL
    return resolvesSymlinks ? standardized.resolvingSymlinksInPath() : standardized
  }
}

public extension LocalUsageCostEstimator {
  func usageInsightsObservationRoots(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> [URL] {
    LocalUsageCostScanner(
      environment: environment,
      homeDirectory: homeDirectory
    )
    .observationRoots(provider: provider, account: account)
  }
}

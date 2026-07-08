import Foundation

/// Assembles the provider descriptors the app actually uses: a live strategy
/// first, then the mock strategy as a fallback. When real credentials are
/// present the live data wins; otherwise the pipeline falls through to demo
/// data, so the app is never empty during development.
public enum ProviderCatalog {
  public static let descriptors: [ProviderDescriptor] = MockProviders.descriptors.map { mock in
    ProviderDescriptor(
      id: mock.id,
      metadata: mock.metadata,
      pipeline: pipeline(for: mock.id)
    )
  }

  private static func pipeline(for id: UsageProvider) -> ProviderFetchPipeline {
    switch id {
    case .codex:
      ProviderFetchPipeline { _ in [CodexUsageStrategy(), MockProviders.codexStrategy] }
    case .claude:
      ProviderFetchPipeline { _ in [ClaudeUsageStrategy(), MockProviders.claudeStrategy] }
    case .glm:
      ProviderFetchPipeline { _ in [MockProviders.glmStrategy] }
    }
  }
}

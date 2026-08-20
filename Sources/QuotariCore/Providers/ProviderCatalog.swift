import Foundation

/// Assembles the live provider descriptors the app uses at runtime.
/// Missing credentials and fetch failures remain failures so the UI can show
/// an honest empty or error state instead of substituting fabricated usage.
public enum ProviderCatalog {
  public static let descriptors: [ProviderDescriptor] = [
    ProviderDescriptor(
      id: .claude,
      metadata: .init(
        displayName: "Claude",
        accent: .init(0.851, 0.467, 0.341),
        supportsWeekly: true
      ), // Anthropic #D97757
      pipeline: ProviderFetchPipeline { _ in
        [
          ClaudeUsageStrategy(
            mirroredCredentialsFileURL: FileManager.default.homeDirectoryForCurrentUser
              .appendingPathComponent(".claude/.credentials.json"),
            credentialLifecycleLogger: .shared
          ),
        ]
      }
    ),
    ProviderDescriptor(
      id: .codex,
      metadata: .init(
        displayName: "Codex",
        accent: .init(0.063, 0.639, 0.498),
        supportsWeekly: true
      ), // OpenAI #10A37F
      pipeline: ProviderFetchPipeline { _ in
        [CodexUsageStrategy(credentialLifecycleLogger: .shared)]
      }
    ),
  ]
}

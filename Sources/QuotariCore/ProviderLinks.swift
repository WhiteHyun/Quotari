import Foundation

public extension UsageProvider {
  var usageDashboardURL: URL {
    switch self {
    case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
    case .claude: URL(string: "https://claude.ai/settings/usage")!
    }
  }
}

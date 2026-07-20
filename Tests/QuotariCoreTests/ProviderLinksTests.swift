@testable import QuotariCore
import Testing

struct ProviderLinksTests {
  @Test func usageDashboardURLsPointToOfficialProviderPages() {
    #expect(UsageProvider.codex.usageDashboardURL.absoluteString == "https://chatgpt.com/codex/settings/usage")
    #expect(UsageProvider.claude.usageDashboardURL.absoluteString == "https://claude.ai/settings/usage")
  }
}

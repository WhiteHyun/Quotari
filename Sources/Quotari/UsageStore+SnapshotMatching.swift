import Foundation
import QuotariCore

extension UsageStore {
  func matchedAccount(for snapshot: UsageSnapshot, provider: UsageProvider) -> ProviderAccount? {
    guard let name = snapshot.account else { return nil }
    return (accounts[provider] ?? []).first { accountMatchesSnapshot($0, name: name) }
  }

  func accountMatchesSnapshot(_ account: ProviderAccount, name: String) -> Bool {
    if account.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame {
      return true
    }
    if account.provider == .claude,
       let email = claudeProfiles[account.id]?.email,
       email.localizedCaseInsensitiveCompare(name) == .orderedSame {
      return true
    }
    return false
  }
}

import Foundation
@testable import QuotariCore
import Testing

struct ClaudeCodeAccountStateTests {
  @Test func replacesOnlyOAuthAccountInClaudeConfiguration() throws {
    let configuration = Data(#"{"theme":"dark","oauthAccount":{"emailAddress":"old@example.com"}}"#.utf8)
    let account = Data(#"{"accountUuid":"new-id","emailAddress":"new@example.com"}"#.utf8)

    let replaced = try ClaudeCodeAccountState.replacingOAuthAccount(
      in: configuration,
      with: account
    )
    let root = try #require(JSONSerialization.jsonObject(with: replaced) as? [String: Any])
    let oauth = try #require(root["oauthAccount"] as? [String: Any])

    #expect(root["theme"] as? String == "dark")
    #expect(oauth["accountUuid"] as? String == "new-id")
    #expect(oauth["emailAddress"] as? String == "new@example.com")
  }

  @Test func synthesizesVerifiedIdentityWithoutCopyingAnotherAccountsSubscription() throws {
    let oldAccount = Data(#"""
    {"accountUuid":"old-id","emailAddress":"old@example.com","organizationName":"Acme",
     "organizationUuid":"org-id","subscriptionType":"team","billingType":"stripe"}
    """#.utf8)
    let profile = ClaudeProfile(
      accountID: "new-id",
      email: "new@example.com",
      organizationName: "Acme"
    )

    let synthesized = try ClaudeCodeAccountState.synthesizedOAuthAccount(
      for: profile,
      template: oldAccount
    )
    let oauth = try #require(JSONSerialization.jsonObject(with: synthesized) as? [String: Any])

    #expect(oauth["accountUuid"] as? String == "new-id")
    #expect(oauth["emailAddress"] as? String == "new@example.com")
    #expect(oauth["organizationUuid"] as? String == "org-id")
    #expect(oauth["subscriptionType"] == nil)
    #expect(oauth["billingType"] == nil)
  }

  @Test func exactSnapshotMatchesAccountUUIDBeforeEmail() {
    let account = Data(#"{"accountUuid":"account-id","emailAddress":"old@example.com"}"#.utf8)

    #expect(ClaudeCodeAccountState.matches(
      account,
      profile: ClaudeProfile(accountID: "account-id", email: "new@example.com")
    ))
    #expect(!ClaudeCodeAccountState.matches(
      account,
      profile: ClaudeProfile(accountID: "another-id", email: "old@example.com")
    ))
  }
}

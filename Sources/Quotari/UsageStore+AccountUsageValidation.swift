import QuotariCore

extension UsageStore {
  func fetchResult(_ value: ProviderFetchResult, belongsTo account: ProviderAccount) -> Bool {
    guard value.sourceKind != .mock else { return false }
    guard let resultScopeID = value.credentialScopeID else {
      // Real OAuth strategies always provide identity evidence. Other injected
      // or non-credential strategies may not have a credential scope to verify.
      return value.sourceKind != .oauth
    }
    if resultScopeID == account.credentialScopeID {
      return true
    }
    if account.credentialSource.isCaptured,
       resultScopeID.hasPrefix("\(account.id):") {
      return true
    }
    guard let transition = Result<ProviderFetchResult, Error>.success(value)
      .credentialTransitionEvidence
    else { return false }
    return transition.targetScopeID == resultScopeID
      && transition.sourceScopeIDs.contains(account.credentialScopeID)
  }
}

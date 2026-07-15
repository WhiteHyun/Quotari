import QuotariCore

extension UsageStore {
  /// Where a previously selected account landed after rediscovery, evaluated
  /// from the account the user *logically* selected: a live stand-in defers
  /// to the saved account it stands in for. When the saved account is
  /// discoverable (again), it is the selection — so a CLI slot reused by
  /// another login falls back to the saved copy instead of being silently
  /// followed. While the saved identity is the live login, the live account
  /// substitutes (fetching with the freshest credential) and the origin is
  /// remembered. A logical account discovery lost entirely is re-listed
  /// as-is so the selection isn't silently dropped.
  func reconciledSelection(
    _ selected: ProviderAccount,
    origin: ProviderAccount?,
    in accounts: inout [ProviderAccount]
  ) async -> SelectionUpdate? {
    let logical = origin ?? selected
    if let visible = accounts.first(where: { $0.id == logical.id }) {
      if automaticallyCapturesDiscoveredAccounts,
         origin == nil,
         visible.credentialScopeID != selected.credentialScopeID {
        // Mutable CLI sources keep a stable row id when the slot is replaced.
        // Without a saved-origin or explicit transition link, the replacement
        // is a different logical account and must not inherit the selection.
        return SelectionUpdate(account: nil, origin: nil)
      }
      if visible == selected, origin == nil {
        return nil
      }
      return SelectionUpdate(account: visible, origin: nil)
    }
    if let live = await accountDiscovery.liveAccount(equivalentTo: logical, among: accounts) {
      if live == selected {
        return nil // the stand-in is already selected; the origin stays
      }
      return SelectionUpdate(account: live, origin: logical)
    }
    accounts.append(logical)
    return logical == selected ? nil : SelectionUpdate(account: logical, origin: nil)
  }
}

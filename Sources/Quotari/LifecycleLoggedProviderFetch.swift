import Foundation
import QuotariCore

struct LifecycleLoggedProviderFetch: Sendable {
  let descriptor: ProviderDescriptor
  let account: ProviderAccount?
  let lifecycleAccount: ProviderAccount?
  let capturedRegistryID: String?
  let interaction: ProviderFetchInteraction
  let now: Date
  let logger: CredentialLifecycleLogger

  func callAsFunction() async -> Result<ProviderFetchResult, Error> {
    logger.record(
      .validationStarted,
      provider: descriptor.id,
      account: lifecycleAccount,
      source: account?.credentialSource,
      interaction: interaction
    )
    let result = await descriptor.fetch(
      now: now,
      account: account,
      capturedRegistryID: capturedRegistryID,
      interaction: interaction
    )
    switch result {
    case .success:
      logger.record(
        .validationSucceeded,
        provider: descriptor.id,
        account: lifecycleAccount,
        source: account?.credentialSource,
        interaction: interaction
      )
    case let .failure(error):
      logger.record(
        .validationFailed,
        provider: descriptor.id,
        account: lifecycleAccount,
        source: account?.credentialSource,
        interaction: interaction,
        failure: .classify(error)
      )
    }
    return result
  }
}

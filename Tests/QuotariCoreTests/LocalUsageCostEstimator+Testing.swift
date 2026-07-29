import Foundation
@testable import QuotariCore

extension LocalUsageCostEstimator {
  static func testing(
    environment: [String: String],
    homeDirectory: URL,
    cacheDirectory: URL? = nil,
    localUsageScanHook: (@Sendable () -> Void)? = nil
  ) -> Self {
    Self(
      environment: environment,
      homeDirectory: homeDirectory,
      cacheDirectory: cacheDirectory,
      pricingCatalogProvider: BundledModelPricingCatalogProvider(),
      localUsageScanHook: localUsageScanHook
    )
  }
}

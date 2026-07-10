import Foundation
@testable import QuotariCore

extension LocalUsageCostEstimator {
  static func testing(
    environment: [String: String],
    homeDirectory: URL,
    cacheDirectory: URL? = nil
  ) -> Self {
    Self(
      environment: environment,
      homeDirectory: homeDirectory,
      cacheDirectory: cacheDirectory,
      pricingCatalogProvider: BundledModelPricingCatalogProvider()
    )
  }
}

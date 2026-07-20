import AppKit
@testable import Quotari
@testable import QuotariCore
import SwiftUI
import Testing

@MainActor
struct ProviderIconAssetTests {
  @Test func selectsAppearanceSpecificOpenAIAssets() {
    #expect(
      ProviderIconAsset.resourceName(for: .codex, colorScheme: .light)
        == "OpenAI-Blossom-Black"
    )
    #expect(
      ProviderIconAsset.resourceName(for: .codex, colorScheme: .dark)
        == "OpenAI-Blossom-White"
    )
  }

  @Test func usesOneClaudeAssetAcrossAppearances() {
    #expect(ProviderIconAsset.resourceName(for: .claude, colorScheme: .light) == "Claude")
    #expect(ProviderIconAsset.resourceName(for: .claude, colorScheme: .dark) == "Claude")
  }

  @Test func bundledProviderAssetsLoadAsImages() {
    for provider in UsageProvider.allCases {
      for colorScheme in [ColorScheme.light, .dark] {
        #expect(ProviderIconAsset.image(for: provider, colorScheme: colorScheme) != nil)
      }
    }
  }
}

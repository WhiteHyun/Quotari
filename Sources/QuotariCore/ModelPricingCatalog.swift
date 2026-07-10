import Foundation

struct ModelPricingKey: Hashable, Sendable {
  let provider: UsageProvider
  let modelID: String

  init(provider: UsageProvider, modelID: String) {
    self.provider = provider
    self.modelID = normalizedModelID(modelID)
  }
}

struct ModelRateComponents: Equatable, Sendable {
  var inputPerMillion: Double?
  var cacheReadPerMillion: Double?
  var cacheWritePerMillion: Double?
  var outputPerMillion: Double?

  init(
    input: Double? = nil,
    cacheRead: Double? = nil,
    cacheWrite: Double? = nil,
    output: Double? = nil
  ) {
    inputPerMillion = input
    cacheReadPerMillion = cacheRead
    cacheWritePerMillion = cacheWrite
    outputPerMillion = output
  }

  func fillingMissing(with fallback: Self?) -> Self {
    Self(
      input: inputPerMillion ?? fallback?.inputPerMillion,
      cacheRead: cacheReadPerMillion ?? fallback?.cacheReadPerMillion,
      cacheWrite: cacheWritePerMillion ?? fallback?.cacheWritePerMillion,
      output: outputPerMillion ?? fallback?.outputPerMillion
    )
  }

  func applying(_ overrides: Self) -> Self {
    Self(
      input: overrides.inputPerMillion ?? inputPerMillion,
      cacheRead: overrides.cacheReadPerMillion ?? cacheReadPerMillion,
      cacheWrite: overrides.cacheWritePerMillion ?? cacheWritePerMillion,
      output: overrides.outputPerMillion ?? outputPerMillion
    )
  }
}

struct LongContextModelPricing: Equatable, Sendable {
  let thresholdTokens: Int
  let overrides: ModelRateComponents
}

struct ModelPricing: Equatable, Sendable {
  let standard: ModelRateComponents
  let longContext: LongContextModelPricing?

  func fillingMissing(with fallback: Self?) -> Self {
    let mergedLongContext: LongContextModelPricing? = if let longContext {
      LongContextModelPricing(
        thresholdTokens: longContext.thresholdTokens,
        overrides: longContext.overrides.fillingMissing(with: fallback?.longContext?.overrides)
      )
    } else {
      fallback?.longContext
    }
    return Self(
      standard: standard.fillingMissing(with: fallback?.standard),
      longContext: mergedLongContext
    )
  }

  func rates(contextInputTokens: Int?) -> ModelRateComponents {
    guard let longContext,
          let contextInputTokens,
          contextInputTokens > longContext.thresholdTokens
    else { return standard }
    return standard.applying(longContext.overrides)
  }
}

struct ModelPricingCatalog: Sendable {
  static let empty = Self(entries: [:])

  private let entries: [ModelPricingKey: ModelPricing]

  init(entries: [ModelPricingKey: ModelPricing]) {
    self.entries = entries
  }

  var isEmpty: Bool {
    entries.isEmpty
  }

  func contains(provider: UsageProvider) -> Bool {
    entries.keys.contains { $0.provider == provider }
  }

  func pricing(for key: ModelPricingKey) -> ModelPricing? {
    entries[key]
  }
}

struct PricingCatalogParseIssue: Equatable, Sendable {
  let modelID: String
  let reason: String
}

struct PricingCatalogParseResult: Sendable {
  let catalog: ModelPricingCatalog
  let issues: [PricingCatalogParseIssue]
}

enum LiteLLMPricingCatalogParser {
  static func parse(_ data: Data) throws -> PricingCatalogParseResult {
    let decoded = try JSONDecoder().decode(LossyEntryDictionary.self, from: data)
    var entries: [ModelPricingKey: ModelPricing] = [:]
    var issues = decoded.issues
    var conflictedKeys = Set<ModelPricingKey>()

    for (rawModelID, entry) in decoded.entries {
      guard let provider = usageProvider(entry.litellmProvider) else { continue }
      let modelID = canonicalModelID(rawModelID, provider: provider)
      let key = ModelPricingKey(provider: provider, modelID: modelID)
      guard !key.modelID.isEmpty else {
        issues.append(.init(modelID: rawModelID, reason: "empty model identifier"))
        continue
      }
      guard let input = validRequiredRate(entry.inputCostPerToken),
            let output = validRequiredRate(entry.outputCostPerToken)
      else {
        issues.append(.init(modelID: rawModelID, reason: "missing or invalid input/output pricing"))
        continue
      }

      let standard = ModelRateComponents(
        input: perMillion(input),
        cacheRead: validOptionalRate(entry.cacheReadInputTokenCost).map(perMillion),
        cacheWrite: validOptionalRate(entry.cacheCreationInputTokenCost).map(perMillion),
        output: perMillion(output)
      )
      let pricing = ModelPricing(
        standard: standard,
        longContext: longContextPricing(entry, provider: provider)
      )

      if entries[key] != nil {
        entries[key] = nil
        conflictedKeys.insert(key)
        issues.append(.init(modelID: key.modelID, reason: "normalized model identifier collision"))
      } else if !conflictedKeys.contains(key) {
        entries[key] = pricing
      }
    }

    return PricingCatalogParseResult(catalog: ModelPricingCatalog(entries: entries), issues: issues)
  }

  private static func usageProvider(_ provider: String?) -> UsageProvider? {
    switch provider?.lowercased() {
    case "openai": .codex
    case "anthropic": .claude
    default: nil
    }
  }

  private static func canonicalModelID(_ modelID: String, provider: UsageProvider) -> String {
    let prefix = switch provider {
    case .codex: "openai/"
    case .claude: "anthropic/"
    case .glm: ""
    }
    if !prefix.isEmpty, modelID.lowercased().hasPrefix(prefix) {
      return String(modelID.dropFirst(prefix.count))
    }
    return modelID
  }

  private static func validRequiredRate(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0 else { return nil }
    return value
  }

  private static func validOptionalRate(_ value: Double?) -> Double? {
    guard let value else { return nil }
    guard value.isFinite, value >= 0 else { return nil }
    return value
  }

  private static func perMillion(_ value: Double) -> Double {
    value * 1_000_000
  }

  private static func longContextPricing(
    _ entry: LiteLLMEntry,
    provider: UsageProvider
  ) -> LongContextModelPricing? {
    let threshold: Int
    let overrides: ModelRateComponents
    switch provider {
    case .codex:
      threshold = 272_000
      overrides = ModelRateComponents(
        input: validOptionalRate(entry.inputCostPerTokenAbove272K).map(perMillion),
        cacheRead: validOptionalRate(entry.cacheReadInputTokenCostAbove272K).map(perMillion),
        cacheWrite: validOptionalRate(entry.cacheCreationInputTokenCostAbove272K).map(perMillion),
        output: validOptionalRate(entry.outputCostPerTokenAbove272K).map(perMillion)
      )
    case .claude:
      threshold = 200_000
      overrides = ModelRateComponents(
        input: validOptionalRate(entry.inputCostPerTokenAbove200K).map(perMillion),
        cacheRead: validOptionalRate(entry.cacheReadInputTokenCostAbove200K).map(perMillion),
        cacheWrite: validOptionalRate(entry.cacheCreationInputTokenCostAbove200K).map(perMillion),
        output: validOptionalRate(entry.outputCostPerTokenAbove200K).map(perMillion)
      )
    case .glm:
      return nil
    }
    let values = [
      overrides.inputPerMillion,
      overrides.cacheReadPerMillion,
      overrides.cacheWritePerMillion,
      overrides.outputPerMillion,
    ]
    guard values.contains(where: { $0 != nil }) else { return nil }
    return LongContextModelPricing(thresholdTokens: threshold, overrides: overrides)
  }
}

private struct LossyEntryDictionary: Decodable {
  let entries: [String: LiteLLMEntry]
  let issues: [PricingCatalogParseIssue]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    var entries: [String: LiteLLMEntry] = [:]
    var issues: [PricingCatalogParseIssue] = []
    for key in container.allKeys {
      do {
        entries[key.stringValue] = try container.decode(LiteLLMEntry.self, forKey: key)
      } catch {
        issues.append(.init(modelID: key.stringValue, reason: "malformed pricing entry"))
      }
    }
    self.entries = entries
    self.issues = issues
  }
}

private struct DynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    nil
  }
}

private struct LiteLLMEntry: Decodable {
  let litellmProvider: String?
  let inputCostPerToken: Double?
  let cacheReadInputTokenCost: Double?
  let cacheCreationInputTokenCost: Double?
  let outputCostPerToken: Double?
  let inputCostPerTokenAbove272K: Double?
  let cacheReadInputTokenCostAbove272K: Double?
  let cacheCreationInputTokenCostAbove272K: Double?
  let outputCostPerTokenAbove272K: Double?
  let inputCostPerTokenAbove200K: Double?
  let cacheReadInputTokenCostAbove200K: Double?
  let cacheCreationInputTokenCostAbove200K: Double?
  let outputCostPerTokenAbove200K: Double?

  enum CodingKeys: String, CodingKey {
    case litellmProvider = "litellm_provider"
    case inputCostPerToken = "input_cost_per_token"
    case cacheReadInputTokenCost = "cache_read_input_token_cost"
    case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
    case outputCostPerToken = "output_cost_per_token"
    case inputCostPerTokenAbove272K = "input_cost_per_token_above_272k_tokens"
    case cacheReadInputTokenCostAbove272K = "cache_read_input_token_cost_above_272k_tokens"
    case cacheCreationInputTokenCostAbove272K = "cache_creation_input_token_cost_above_272k_tokens"
    case outputCostPerTokenAbove272K = "output_cost_per_token_above_272k_tokens"
    case inputCostPerTokenAbove200K = "input_cost_per_token_above_200k_tokens"
    case cacheReadInputTokenCostAbove200K = "cache_read_input_token_cost_above_200k_tokens"
    case cacheCreationInputTokenCostAbove200K = "cache_creation_input_token_cost_above_200k_tokens"
    case outputCostPerTokenAbove200K = "output_cost_per_token_above_200k_tokens"
  }
}

func normalizedModelID(_ model: String?) -> String {
  model?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
    .replacingOccurrences(of: "_", with: "-") ?? ""
}

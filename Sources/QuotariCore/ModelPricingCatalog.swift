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
  let longContexts: [LongContextModelPricing]

  init(standard: ModelRateComponents, longContext: LongContextModelPricing?) {
    self.init(standard: standard, longContexts: longContext.map { [$0] } ?? [])
  }

  init(standard: ModelRateComponents, longContexts: [LongContextModelPricing]) {
    self.standard = standard
    self.longContexts = longContexts.sorted { $0.thresholdTokens < $1.thresholdTokens }
  }

  var longContext: LongContextModelPricing? {
    longContexts.first
  }

  func fillingMissing(with fallback: Self?) -> Self {
    let mergedLongContexts: [LongContextModelPricing] = if longContexts.isEmpty {
      fallback?.longContexts ?? []
    } else {
      longContexts.map { longContext in
        let fallbackRates = fallback?.longContexts
          .first { $0.thresholdTokens == longContext.thresholdTokens }?
          .overrides
        return LongContextModelPricing(
          thresholdTokens: longContext.thresholdTokens,
          overrides: longContext.overrides.fillingMissing(with: fallbackRates)
        )
      }
    }
    return Self(
      standard: standard.fillingMissing(with: fallback?.standard),
      longContexts: mergedLongContexts
    )
  }

  func rates(contextInputTokens: Int?) -> ModelRateComponents {
    guard let contextInputTokens,
          let longContext = longContexts.last(where: { contextInputTokens > $0.thresholdTokens })
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
        longContexts: longContextPricing(entry)
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

  private static func longContextPricing(_ entry: LiteLLMEntry) -> [LongContextModelPricing] {
    entry.longContextRates.compactMap { threshold, rates in
      let overrides = ModelRateComponents(
        input: validOptionalRate(rates.input).map(perMillion),
        cacheRead: validOptionalRate(rates.cacheRead).map(perMillion),
        cacheWrite: validOptionalRate(rates.cacheWrite).map(perMillion),
        output: validOptionalRate(rates.output).map(perMillion)
      )
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
  let longContextRates: [Int: LiteLLMLongContextRates]

  init(from decoder: Decoder) throws {
    let standard = try decoder.container(keyedBy: CodingKeys.self)
    litellmProvider = try standard.decodeIfPresent(String.self, forKey: .litellmProvider)
    inputCostPerToken = try standard.decodeIfPresent(Double.self, forKey: .inputCostPerToken)
    cacheReadInputTokenCost = try standard.decodeIfPresent(Double.self, forKey: .cacheReadInputTokenCost)
    cacheCreationInputTokenCost = try standard.decodeIfPresent(Double.self, forKey: .cacheCreationInputTokenCost)
    outputCostPerToken = try standard.decodeIfPresent(Double.self, forKey: .outputCostPerToken)

    let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
    var tiers: [Int: LiteLLMLongContextRates] = [:]
    for key in dynamic.allKeys {
      guard let (threshold, component) = LiteLLMLongContextKey.parse(key.stringValue) else { continue }
      let value = try dynamic.decodeIfPresent(Double.self, forKey: key)
      var rates = tiers[threshold, default: LiteLLMLongContextRates()]
      rates.set(value, for: component)
      tiers[threshold] = rates
    }
    longContextRates = tiers
  }

  enum CodingKeys: String, CodingKey {
    case litellmProvider = "litellm_provider"
    case inputCostPerToken = "input_cost_per_token"
    case cacheReadInputTokenCost = "cache_read_input_token_cost"
    case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
    case outputCostPerToken = "output_cost_per_token"
  }
}

private struct LiteLLMLongContextRates {
  var input: Double?
  var cacheRead: Double?
  var cacheWrite: Double?
  var output: Double?

  mutating func set(_ value: Double?, for component: LiteLLMLongContextComponent) {
    switch component {
    case .input:
      input = value
    case .cacheRead:
      cacheRead = value
    case .cacheWrite:
      cacheWrite = value
    case .output:
      output = value
    }
  }
}

private enum LiteLLMLongContextComponent {
  case input
  case cacheRead
  case cacheWrite
  case output
}

private enum LiteLLMLongContextKey {
  private static let suffix = "k_tokens"
  private static let prefixes: [(String, LiteLLMLongContextComponent)] = [
    ("input_cost_per_token_above_", .input),
    ("cache_read_input_token_cost_above_", .cacheRead),
    ("cache_creation_input_token_cost_above_", .cacheWrite),
    ("output_cost_per_token_above_", .output),
  ]

  static func parse(_ key: String) -> (threshold: Int, component: LiteLLMLongContextComponent)? {
    guard key.hasSuffix(suffix) else { return nil }
    for (prefix, component) in prefixes where key.hasPrefix(prefix) {
      let start = key.index(key.startIndex, offsetBy: prefix.count)
      let end = key.index(key.endIndex, offsetBy: -suffix.count)
      guard let thousands = Int(key[start ..< end]),
            thousands > 0,
            thousands <= Int.max / 1000
      else { return nil }
      return (thousands * 1000, component)
    }
    return nil
  }
}

func normalizedModelID(_ model: String?) -> String {
  model?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
    .replacingOccurrences(of: "_", with: "-") ?? ""
}

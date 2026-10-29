import AppKit
import Foundation
import Observation
import QuotariCore

enum MenuBarUsageSource: Codable, Equatable, Hashable, Sendable {
  case mostConstrained
  case provider(UsageProvider)
}

/// Which quota window drives the menu-bar value.
enum MenuBarQuotaWindow: String, Codable, CaseIterable, Hashable, Sendable {
  /// The most constrained of the session and weekly windows.
  case automatic
  case session
  case weekly
}

enum MenuBarQuotaPresentation: String, Codable, CaseIterable, Hashable, Sendable {
  case remaining
  case used
}

/// What the menu bar shows beside the mascot.
enum MenuBarValueMode: String, Codable, CaseIterable, Hashable, Sendable {
  case hidden
  case remainingQuota
  case todayCost
}

struct MenuBarPreferences: Codable, Equatable, Hashable, Sendable {
  var valueMode: MenuBarValueMode
  var usageSource: MenuBarUsageSource
  var animatesMascot: Bool
  var mascot: MenuBarMascot
  var quotaWindow: MenuBarQuotaWindow
  var quotaPresentation: MenuBarQuotaPresentation
  /// Nil until the user picks one; today's cost never picks a provider silently.
  var costSource: UsageProvider?

  init(
    valueMode: MenuBarValueMode = .hidden,
    usageSource: MenuBarUsageSource = .mostConstrained,
    animatesMascot: Bool = true,
    mascot: MenuBarMascot = .builtIn,
    quotaWindow: MenuBarQuotaWindow = .automatic,
    quotaPresentation: MenuBarQuotaPresentation = .remaining,
    costSource: UsageProvider? = nil
  ) {
    self.valueMode = valueMode
    self.usageSource = usageSource
    self.animatesMascot = animatesMascot
    self.mascot = mascot
    self.quotaWindow = quotaWindow
    self.quotaPresentation = quotaPresentation
    self.costSource = costSource
  }

  private enum CodingKeys: String, CodingKey {
    case valueMode
    case showsRemainingPercent
    case usageSource
    case animatesMascot
    case mascot
    case quotaWindow
    case quotaPresentation
    case costSource
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let valueMode = try container.decodeIfPresent(MenuBarValueMode.self, forKey: .valueMode) {
      self.valueMode = valueMode
    } else {
      let showsRemainingPercent = try container.decode(Bool.self, forKey: .showsRemainingPercent)
      valueMode = showsRemainingPercent ? .remainingQuota : .hidden
    }
    usageSource = try container.decode(MenuBarUsageSource.self, forKey: .usageSource)
    animatesMascot = try container.decode(Bool.self, forKey: .animatesMascot)
    mascot = try container.decodeIfPresent(MenuBarMascot.self, forKey: .mascot) ?? .builtIn
    quotaWindow = try container.decodeIfPresent(MenuBarQuotaWindow.self, forKey: .quotaWindow) ?? .automatic
    quotaPresentation = try container.decodeIfPresent(
      MenuBarQuotaPresentation.self,
      forKey: .quotaPresentation
    ) ?? .remaining
    costSource = try container.decodeIfPresent(UsageProvider.self, forKey: .costSource)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(valueMode, forKey: .valueMode)
    // Earlier versions require this key, so a rollback keeps the preferences.
    try container.encode(valueMode == .remainingQuota, forKey: .showsRemainingPercent)
    try container.encode(usageSource, forKey: .usageSource)
    try container.encode(animatesMascot, forKey: .animatesMascot)
    try container.encode(mascot, forKey: .mascot)
    try container.encode(quotaWindow, forKey: .quotaWindow)
    try container.encode(quotaPresentation, forKey: .quotaPresentation)
    try container.encodeIfPresent(costSource, forKey: .costSource)
  }
}

@MainActor
@Observable
final class MenuBarPreferencesController {
  static let defaultsKey = "menuBar.preferences.v1"

  private(set) var preferences: MenuBarPreferences
  private(set) var customMascotName: String?
  private(set) var customMascotFrameCount = 0
  private(set) var customMascotRevision = 0
  private(set) var isCustomMascotOperationInProgress = false

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored let customMascotArchiveURL: URL
  @ObservationIgnored private var customMascotFrames: [NSImage] = []
  @ObservationIgnored private var customMascotRestoreTask: Task<Void, Never>?

  var valueMode: MenuBarValueMode {
    get { preferences.valueMode }
    set { setValueMode(newValue) }
  }

  var costSource: UsageProvider? {
    get { preferences.costSource }
    set { setCostSource(newValue) }
  }

  var usageSource: MenuBarUsageSource {
    get { preferences.usageSource }
    set { setUsageSource(newValue) }
  }

  var quotaWindow: MenuBarQuotaWindow {
    get { preferences.quotaWindow }
    set { setQuotaWindow(newValue) }
  }

  var quotaPresentation: MenuBarQuotaPresentation {
    get { preferences.quotaPresentation }
    set { setQuotaPresentation(newValue) }
  }

  var animatesMascot: Bool {
    get { preferences.animatesMascot }
    set { setAnimatesMascot(newValue) }
  }

  var mascot: MenuBarMascot {
    get { preferences.mascot }
    set { setMascot(newValue) }
  }

  var hasCustomMascot: Bool {
    !customMascotFrames.isEmpty
  }

  init(
    defaults: UserDefaults = .standard,
    customMascotArchiveURL: URL? = nil
  ) {
    self.defaults = defaults
    self.customMascotArchiveURL = customMascotArchiveURL ?? CustomMascotStore.defaultArchiveURL()
    if defaults.object(forKey: Self.defaultsKey) == nil {
      preferences = MenuBarPreferences()
    } else if let data = defaults.data(forKey: Self.defaultsKey),
              let restored = try? JSONDecoder().decode(MenuBarPreferences.self, from: data) {
      preferences = restored
    } else {
      let fallback = MenuBarPreferences()
      preferences = fallback
      Self.save(fallback, defaults: defaults)
    }

    if FileManager.default.fileExists(atPath: self.customMascotArchiveURL.path) {
      beginCustomMascotRestore()
    } else if preferences.mascot == .custom {
      preferences.mascot = .builtIn
      persist()
    }
  }

  func setValueMode(_ valueMode: MenuBarValueMode) {
    guard preferences.valueMode != valueMode else { return }
    preferences.valueMode = valueMode
    persist()
  }

  func setCostSource(_ costSource: UsageProvider?) {
    guard preferences.costSource != costSource else { return }
    preferences.costSource = costSource
    persist()
  }

  func setUsageSource(_ usageSource: MenuBarUsageSource) {
    guard preferences.usageSource != usageSource else { return }
    preferences.usageSource = usageSource
    persist()
  }

  func setQuotaWindow(_ quotaWindow: MenuBarQuotaWindow) {
    guard preferences.quotaWindow != quotaWindow else { return }
    preferences.quotaWindow = quotaWindow
    persist()
  }

  func setQuotaPresentation(_ quotaPresentation: MenuBarQuotaPresentation) {
    guard preferences.quotaPresentation != quotaPresentation else { return }
    preferences.quotaPresentation = quotaPresentation
    persist()
  }

  func setAnimatesMascot(_ animatesMascot: Bool) {
    guard preferences.animatesMascot != animatesMascot else { return }
    preferences.animatesMascot = animatesMascot
    persist()
  }

  func setMascot(_ mascot: MenuBarMascot) {
    guard mascot != .custom || hasCustomMascot,
          preferences.mascot != mascot
    else { return }
    preferences.mascot = mascot
    persist()
  }

  func importCustomMascot(from urls: [URL]) async throws {
    guard !isCustomMascotOperationInProgress else {
      throw CustomMascotError.operationInProgress
    }
    isCustomMascotOperationInProgress = true
    defer { isCustomMascotOperationInProgress = false }

    let selectsImportedMascot = !hasCustomMascot
    let archiveURL = customMascotArchiveURL
    let imported = try await Task.detached(priority: .userInitiated) {
      let imported = try CustomMascotStore.importedMascot(from: urls)
      try CustomMascotStore.save(imported.mascot, to: archiveURL)
      return imported
    }.value
    let frames = IconRenderer.customMascotFrames(from: imported.decodedFrames)

    customMascotFrames = frames
    customMascotName = imported.mascot.name
    customMascotFrameCount = frames.count
    customMascotRevision += 1
    if selectsImportedMascot {
      preferences.mascot = .custom
      persist()
    }
  }

  func removeCustomMascot() async throws {
    guard !isCustomMascotOperationInProgress else {
      throw CustomMascotError.operationInProgress
    }
    isCustomMascotOperationInProgress = true
    defer { isCustomMascotOperationInProgress = false }

    let archiveURL = customMascotArchiveURL
    try await Task.detached(priority: .userInitiated) {
      try CustomMascotStore.remove(from: archiveURL)
    }.value
    customMascotFrames = []
    customMascotName = nil
    customMascotFrameCount = 0
    customMascotRevision += 1
    preferences.mascot = .builtIn
    persist()
  }

  func mascotIcon(frame: Int) -> NSImage {
    guard preferences.mascot == .custom,
          let customIcon = customMascotIcon(frame: frame)
    else {
      return IconRenderer.mascotIcon(frame: frame)
    }
    return customIcon
  }

  func customMascotIcon(frame: Int) -> NSImage? {
    guard !customMascotFrames.isEmpty else { return nil }
    return customMascotFrames[frame % customMascotFrames.count]
  }

  var mascotFrameCount: Int {
    if preferences.mascot == .custom, !customMascotFrames.isEmpty {
      return customMascotFrames.count
    }
    return IconRenderer.frameCount
  }

  func waitForCustomMascotRestore() async {
    await customMascotRestoreTask?.value
  }

  private func beginCustomMascotRestore() {
    isCustomMascotOperationInProgress = true
    let archiveURL = customMascotArchiveURL
    customMascotRestoreTask = Task { [weak self] in
      let loaded = await Task.detached(priority: .userInitiated) {
        try? CustomMascotStore.load(from: archiveURL)
      }.value
      guard let self else { return }

      if let loaded {
        let frames = IconRenderer.customMascotFrames(from: loaded.decodedFrames)
        customMascotFrames = frames
        customMascotName = loaded.mascot.name
        customMascotFrameCount = frames.count
        customMascotRevision += 1
      } else if preferences.mascot == .custom {
        preferences.mascot = .builtIn
        persist()
      }
      isCustomMascotOperationInProgress = false
      customMascotRestoreTask = nil
    }
  }

  private func persist() {
    Self.save(preferences, defaults: defaults)
  }

  private static func save(_ preferences: MenuBarPreferences, defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(preferences) else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}

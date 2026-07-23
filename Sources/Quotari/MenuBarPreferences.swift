import AppKit
import Foundation
import Observation
import QuotariCore

enum MenuBarUsageSource: Codable, Equatable, Hashable, Sendable {
  case mostConstrained
  case provider(UsageProvider)
}

struct MenuBarPreferences: Codable, Equatable, Hashable, Sendable {
  var showsRemainingPercent: Bool
  var usageSource: MenuBarUsageSource
  var animatesMascot: Bool
  var mascot: MenuBarMascot

  init(
    showsRemainingPercent: Bool = false,
    usageSource: MenuBarUsageSource = .mostConstrained,
    animatesMascot: Bool = true,
    mascot: MenuBarMascot = .builtIn
  ) {
    self.showsRemainingPercent = showsRemainingPercent
    self.usageSource = usageSource
    self.animatesMascot = animatesMascot
    self.mascot = mascot
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    showsRemainingPercent = try container.decode(Bool.self, forKey: .showsRemainingPercent)
    usageSource = try container.decode(MenuBarUsageSource.self, forKey: .usageSource)
    animatesMascot = try container.decode(Bool.self, forKey: .animatesMascot)
    mascot = try container.decodeIfPresent(MenuBarMascot.self, forKey: .mascot) ?? .builtIn
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

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let customMascotArchiveURL: URL
  @ObservationIgnored private var customMascotFrames: [NSImage] = []

  var showsRemainingPercent: Bool {
    get { preferences.showsRemainingPercent }
    set { setShowsRemainingPercent(newValue) }
  }

  var usageSource: MenuBarUsageSource {
    get { preferences.usageSource }
    set { setUsageSource(newValue) }
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

    restoreCustomMascot()
    if preferences.mascot == .custom, !hasCustomMascot {
      preferences.mascot = .builtIn
      persist()
    }
  }

  func setShowsRemainingPercent(_ showsRemainingPercent: Bool) {
    guard preferences.showsRemainingPercent != showsRemainingPercent else { return }
    preferences.showsRemainingPercent = showsRemainingPercent
    persist()
  }

  func setUsageSource(_ usageSource: MenuBarUsageSource) {
    guard preferences.usageSource != usageSource else { return }
    preferences.usageSource = usageSource
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

  func importCustomMascot(from urls: [URL]) throws {
    let selectsImportedMascot = !hasCustomMascot
    let imported = try CustomMascotStore.importedMascot(from: urls)
    let frames = IconRenderer.customMascotFrames(from: imported.decodedFrames)
    try CustomMascotStore.save(imported.mascot, to: customMascotArchiveURL)

    customMascotFrames = frames
    customMascotName = imported.mascot.name
    customMascotFrameCount = frames.count
    customMascotRevision += 1
    if selectsImportedMascot {
      preferences.mascot = .custom
      persist()
    }
  }

  func removeCustomMascot() throws {
    try CustomMascotStore.remove(from: customMascotArchiveURL)
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

  private func restoreCustomMascot() {
    guard let loaded = try? CustomMascotStore.load(from: customMascotArchiveURL) else { return }
    let frames = IconRenderer.customMascotFrames(from: loaded.decodedFrames)
    customMascotFrames = frames
    customMascotName = loaded.mascot.name
    customMascotFrameCount = frames.count
  }

  private func persist() {
    Self.save(preferences, defaults: defaults)
  }

  private static func save(_ preferences: MenuBarPreferences, defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(preferences) else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}

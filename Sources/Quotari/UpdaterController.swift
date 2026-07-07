import Foundation
import Sparkle

/// Wraps Sparkle's updater. Active only in a packaged `.app` whose Info.plist
/// carries a Sparkle feed (`SUFeedURL`); `swift run` and test builds get the
/// disabled state so development never triggers update checks.
@MainActor
@Observable
final class UpdaterController {
  static let shared = UpdaterController()

  private let controller: SPUStandardUpdaterController?

  var isAvailable: Bool {
    controller != nil
  }

  private init() {
    let bundle = Bundle.main
    guard bundle.bundleURL.pathExtension == "app",
          bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
    else {
      controller = nil
      return
    }
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}

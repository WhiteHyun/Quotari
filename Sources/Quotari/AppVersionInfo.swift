import Foundation
import SwiftUI

struct AppVersionInfo: Equatable, Sendable {
  let version: String
  let build: String?

  init?(infoDictionary: [String: Any]?) {
    guard let version = infoDictionary?["CFBundleShortVersionString"] as? String,
          !version.isEmpty
    else { return nil }

    self.version = version
    if let build = infoDictionary?["CFBundleVersion"] as? String,
       !build.isEmpty,
       build != version {
      self.build = build
    } else {
      build = nil
    }
  }

  init(version: String, build: String? = nil) {
    self.version = version
    self.build = build == version ? nil : build
  }

  var displayVersion: String {
    if let build {
      "\(version) (\(build))"
    } else {
      version
    }
  }
}

extension EnvironmentValues {
  @Entry var appVersionInfo: AppVersionInfo? = AppVersionInfo(infoDictionary: Bundle.main.infoDictionary)
}

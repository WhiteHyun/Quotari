// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Quotari",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .library(name: "QuotariCore", targets: ["QuotariCore"]),
    .executable(name: "Quotari", targets: ["Quotari"]),
  ],
  dependencies: [
    .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.3.0"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.65.0"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
  ],
  targets: [
    // Domain logic: models and live provider integrations. UI-agnostic.
    .target(
      name: "QuotariCore",
      dependencies: [
        .product(name: "TOML", package: "swift-toml"),
      ],
      plugins: [
        .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
      ]
    ),
    // The menu-bar app (SwiftUI MenuBarExtra + a hand-rendered CG icon).
    .executableTarget(
      name: "Quotari",
      dependencies: [
        "QuotariCore",
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
        .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      resources: [
        .process("Resources"),
      ],
      plugins: [
        .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
      ]
    ),
    .testTarget(
      name: "QuotariCoreTests",
      dependencies: ["QuotariCore"],
      exclude: ["Fixtures"],
      plugins: [
        .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
      ]
    ),
    // macOS-only: renders the SwiftUI dashboard to PNGs for visual review.
    .testTarget(
      name: "QuotariAppTests",
      dependencies: ["Quotari", "QuotariCore"],
      plugins: [
        .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
      ]
    ),
  ],
  // Swift 6 language mode: full data-race safety enforced at compile time.
  swiftLanguageModes: [.v6]
)

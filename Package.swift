// swift-tools-version: 6.0
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
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
  ],
  targets: [
    // Domain logic: models, provider abstraction, mock fetch. UI-agnostic.
    .target(name: "QuotariCore"),
    // The menu-bar app (SwiftUI MenuBarExtra + a hand-rendered CG icon).
    .executableTarget(
      name: "Quotari",
      dependencies: [
        "QuotariCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ]
    ),
    .testTarget(
      name: "QuotariCoreTests",
      dependencies: ["QuotariCore"]
    ),
    // macOS-only: renders the SwiftUI dashboard to PNGs for visual review.
    .testTarget(
      name: "QuotariAppTests",
      dependencies: ["Quotari", "QuotariCore"]
    ),
  ],
  // Swift 6 language mode: full data-race safety enforced at compile time.
  swiftLanguageModes: [.v6]
)

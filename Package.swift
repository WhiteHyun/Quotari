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
    targets: [
        // Domain logic: models, provider abstraction, mock fetch. UI-agnostic.
        .target(
            name: "QuotariCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
        // The menu-bar app (SwiftUI MenuBarExtra + a hand-rendered CG icon).
        .executableTarget(
            name: "Quotari",
            dependencies: ["QuotariCore"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
        .testTarget(
            name: "QuotariCoreTests",
            dependencies: ["QuotariCore"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
    ],
    // Approachable migration: language mode 5 + StrictConcurrency as warnings,
    // mirroring the app this is modeled after. Flip to .v6 when you're ready.
    swiftLanguageModes: [.v5])

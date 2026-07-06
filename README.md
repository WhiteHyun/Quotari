# Quotari

A macOS menu-bar app that shows your AI coding subscriptions' usage, limits, and
reset times at a glance. This repo is the **minimal vertical slice**: a runnable
menu-bar app driven by a mock provider, structured with a clean
Descriptor / Strategy / Registry provider abstraction.

## Run

```sh
swift run Quotari      # menu-bar app (mock data, no network)
swift test             # QuotariCore unit tests
```

The app runs as a menu-bar-only (accessory) app — look for the gauge icon in the
menu bar, not the Dock.

## Structure

```
Sources/
├── QuotariCore/                 # UI-agnostic domain logic (also reusable by a CLI later)
│   ├── UsageProvider.swift      # enum = single source of truth for provider identity
│   ├── UsageModels.swift        # RateWindow / UsageWindowKind / UsageSnapshot
│   ├── ProviderFetch.swift      # Strategy protocol + fallback Pipeline
│   ├── ProviderDescriptor.swift # Descriptor + Registry (completeness-checked)
│   ├── UsageFormatter.swift     # pure display helpers
│   └── Providers/Mock/          # reference strategy (MockFetchStrategy) + 3 demo providers
└── Quotari/                     # the SwiftUI menu-bar app
    ├── QuotariApp.swift         # @main, MenuBarExtra(.window) + Settings
    ├── UsageStore.swift         # @MainActor @Observable state + refresh loop
    ├── IconRenderer.swift       # the one hand-rendered piece: CG gauge NSImage
    ├── DashboardView.swift      # the popover
    ├── ProviderCardView.swift   # one provider card
    └── PreferencesView.swift    # settings
```

## Adding a real provider

1. Add a case to `UsageProvider`.
2. Write a `ProviderFetchStrategy` (API / OAuth / web / CLI) — model on `MockFetchStrategy`.
3. Register a `ProviderDescriptor` in `MockProviders.descriptors` (rename to your own registry file).
4. `ProviderRegistry.isComplete` asserts you didn't miss a case.

## Not yet included (deliberately)

CLI target, WidgetKit target, real network fetch, Keychain credential storage,
Sparkle auto-update, Homebrew cask, Developer ID signing + notarization. These
come after the UI feels right.

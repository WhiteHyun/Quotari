# Quotari

Quotari is a macOS menu-bar app for checking Claude Code and Codex usage,
remaining quota, reset times, and estimated local API cost at a glance.

## Features

- Tries live Claude and Codex usage from their existing OAuth credentials first,
  with built-in demo fallback in Automatic mode when the live strategy is
  unavailable or returns a fallback-eligible response.
- Refreshes Claude credentials and saved Codex credentials. Refreshing a live
  Codex `auth.json` remains the Codex CLI's responsibility.
- Discovers CLI accounts from the Claude keychain and credentials file, the
  Claude OAuth environment variable, and Codex `auth.json` locations including
  `CODEX_HOME`. Automatic Codex usage follows the CLI's effective location,
  preferring `$CODEX_HOME/auth.json` when configured.
- Saves renewable account copies in Quotari-owned Keychain items and switches
  the credential slot used by each CLI after preserving the current login.
  Close active Claude Code or Codex sessions before switching so their separate
  credential refresh loops cannot race Quotari's write.
- Estimates costs from local Claude and Codex usage logs. For observed models,
  a cached remote LiteLLM catalog supplies the preferred current rates; the
  bundled catalog fills missing data and provides an offline fallback.
  File-backed live accounts can scope their log roots; Claude keychain or
  environment accounts share local caches, and saved registry accounts have no
  local logs.
- Provides persistent provider toggles, account selection, configurable refresh
  intervals, launch at login in packaged app builds, menu-bar display options,
  mascot animation, and a global dashboard shortcut.
- Sends optional quota warning, critical, and reset notifications with
  per-provider controls.
- Integrates Sparkle update checks in packaged builds that include feed
  configuration; source and test builds keep update checks disabled.

## Run

Quotari requires macOS 14 or later and Swift 6.2.

```sh
swift run Quotari      # run the menu-bar app from source
swift test             # run QuotariCore and app-level tests
```

The source build tries live CLI credentials first. Automatic mode may use demo
data when the live strategy is unavailable or a response is eligible for
fallback. The app runs as an accessory app, so look for the flame mascot in the
menu bar rather than a Dock icon.

## Structure

```text
Sources/
├── QuotariCore/                         # UI-agnostic domain and integration logic
│   ├── Providers/
│   │   ├── Claude/                      # credentials, refresh, profile, parsing, fetch
│   │   ├── Codex/                       # credentials, refresh, parsing, fetch
│   │   ├── Mock/                        # demo fallback strategies
│   │   └── ProviderCatalog.swift        # live-first provider pipelines
│   ├── ProviderAccount*.swift           # account model, discovery, and selection
│   ├── CapturedAccountStore.swift       # Quotari-owned Keychain account registry
│   ├── AccountCaptureService.swift      # save renewable CLI credentials
│   ├── AccountSwitchService*.swift      # preserve and switch live CLI accounts
│   ├── LocalUsage*.swift                # local log parsing, cost estimation, and cache
│   ├── ModelPricingCatalog.swift        # bundled model prices
│   ├── RemoteModelPricingCatalogStore.swift # cached remote price updates
│   └── Usage*.swift                     # provider identity, snapshots, pace, formatting
└── Quotari/                              # SwiftUI menu-bar application
    ├── QuotariApp.swift                  # MenuBarExtra entry point
    ├── UsageStore*.swift                 # refresh, account, cost, provider, and alert state
    ├── DashboardView.swift               # menu-bar dashboard
    ├── ProviderCardView.swift            # provider usage card
    ├── ProviderAccountPopover.swift      # account save, selection, and switching UI
    ├── CostSectionView.swift              # local cost summary
    ├── PreferencesView.swift             # General / Accounts / Notifications / About tabs
    ├── *PreferencesView.swift            # focused settings tab content
    ├── QuotaNotification*.swift          # quota alert policy and delivery
    └── UpdaterController.swift           # packaged-app Sparkle integration
```

`QuotariCore` is a library target so provider, account, usage, and cost logic
remain independent of the macOS UI. `Quotari` owns app lifecycle, presentation,
preferences, and user notifications.

## Adding a provider

1. Add the provider identity and metadata.
2. Implement its credential loader and `ProviderFetchStrategy`.
3. Register the live strategy and demo fallback in `ProviderCatalog`.
4. Add account discovery, selection, and local-cost integration where the
   provider supports them.
5. Extend registry completeness and provider-specific tests.

## Repository scope

The Swift package currently contains the macOS app and `QuotariCore` library;
there is no CLI or WidgetKit target. Packaging, Developer ID signing,
notarization, Sparkle appcast generation, GitHub Releases, and Homebrew tap steps
are documented in [docs/RELEASING.md](docs/RELEASING.md).

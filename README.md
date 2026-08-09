# Quotari

Quotari is a macOS menu-bar app for checking Claude Code and Codex usage,
remaining quota, reset times, and estimated local API cost at a glance.

## Features

- Shows only live Claude and Codex usage from existing OAuth credentials.
  Missing accounts and fetch failures stay visible as actionable empty or error
  states; Quotari never substitutes sample usage at runtime.
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
- Adds Codex accounts through an isolated `CODEX_HOME`. For Claude, Quotari
  preserves the current renewable login, opens Claude Code's browser login,
  automatically registers the changed account, and restores the previous CLI
  account when login or identity verification fails.
- Estimates costs from local Claude and Codex usage logs. For observed models,
  a cached remote LiteLLM catalog supplies the preferred current rates; the
  bundled catalog fills missing data and provides an offline fallback.
  File-backed live accounts can scope their log roots; Claude keychain or
  environment accounts share local caches, and saved registry accounts have no
  local logs.
- Provides persistent provider toggles, account selection, configurable refresh
  intervals, launch at login in packaged app builds, menu-bar display options,
  built-in or user-created mascot animation, and a global dashboard shortcut.
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

The source build uses the same live-only provider catalog as the packaged app.
Automatic mode selects the effective live CLI credential; it does not generate
sample usage when no account is available. The app runs as an accessory app,
so look for the flame mascot in the menu bar rather than a Dock icon.

### Localization

`Sources/Quotari/Resources/Localizable.xcstrings` is the only localization
source of truth. The `CompileStringCatalogPlugin` build-tool plugin compiles the
catalog into runtime `.lproj/Localizable.strings` resources for `swift build`,
`swift run`, and `swift test`. Generated `.strings` files are build artifacts
and must not be checked into the repository.

Run `Scripts/check-localizations.sh` to validate that the catalog can produce
the supported Korean localization.

### Custom mascots

Open **Settings → General → Menu Bar → Custom mascot** to import an animation.
Quotari accepts either format:

- 2–32 separate PNG frames with identical pixel dimensions. Files play in
  natural filename order, so names such as `owl-frame-0.png`,
  `owl-frame-1.png`, and `owl-frame-2.png` are recommended.
- One horizontal PNG sprite sheet containing 2–32 square frames. The sheet
  width must be an exact multiple of its height.

PNG files may total up to 10 MB. A transparent background is recommended.
Quotari scales frames to 18 points high in the menu bar, preserves wider
characters up to 50 points, and stores an app-owned copy in Application
Support so the source files can be moved or deleted after import.

### Live Claude account-switch E2E

The regular test suite never reads or changes live credentials. An explicit
operator-only E2E exercises the production `UsageStore` path across a real saved
Claude account: it switches the shared Claude Code credential, performs the
immediate Anthropic usage fetch, starts a new `claude auth status` process to
verify that the target is still logged in, switches back, verifies the restored
login in another fresh process, and removes a newly created original-login
backup only when its account identity proves that the round trip created it.

Quit the Quotari app and every Claude Code session first. The target must already
be saved in Quotari, have verified account and organization UUIDs that agree
with its saved Claude Code state, and differ from the current CLI login by that
exact identity. Then run:

```sh
./Scripts/run-claude-switch-e2e.sh \
  --target-id '<saved-account-registry-id>' \
  --confirm-live-switch
```

This test calls live Anthropic profile and usage endpoints and mutates the real
Claude Code Keychain/credentials slots. It is disabled unless the script's
explicit opt-in environment is present and should not run in CI. The runner
accepts only the non-secret registry identifier, so an account email does not
appear in shell history or the process list. A per-user machine lock rejects
overlapping runners before either process can touch the shared credential slots.
The lock is kernel-managed, so a stale lock file after a crash does not block the
next run. If the runner receives HUP, INT, or TERM after the test starts, it keeps
the test in a separate process session and holds that lock until credential
restoration finishes, then exits with status 130.

## Structure

```text
Sources/
├── QuotariCore/                         # UI-agnostic domain and integration logic
│   ├── Providers/
│   │   ├── Claude/                      # credentials, refresh, profile, parsing, fetch
│   │   ├── Codex/                       # credentials, refresh, parsing, fetch
│   │   └── ProviderCatalog.swift        # live-only provider pipelines
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
3. Register the live strategy in `ProviderCatalog`.
4. Add account discovery, selection, and local-cost integration where the
   provider supports them.
5. Extend registry completeness and provider-specific tests.

## Repository scope

The Swift package currently contains the macOS app and `QuotariCore` library;
there is no CLI or WidgetKit target. Packaging, Developer ID signing,
notarization, Sparkle appcast generation, GitHub Releases, and Homebrew tap steps
are documented in [docs/RELEASING.md](docs/RELEASING.md).

# Usage Insights Technical Design

Status: Proposed

Last updated: 2026-07-23

Product specification: [Usage Insights Product Specification](usage-insights-product-spec.md)

## Design overview

Usage Insights extends the existing local cost pipeline instead of creating an
independent parser or placing analysis logic in SwiftUI.

The design has four layers:

```text
Local session logs
  → provider-specific scan and deduplication
  → structured local usage analysis and versioned cache
  → UsageStore coordination and event-driven invalidation
  → compact popover + Analytics window + menu-bar metric
```

Live quota fetching remains separate. A local analysis may enrich a live
`UsageSnapshot`, but it cannot delay or replace the provider snapshot.

## Current architecture

Relevant existing types and responsibilities:

- `LocalUsageCostScanner` locates and parses Claude and Codex logs.
- `LocalTokenRecord` retains day, model, token totals, and context size.
- `LocalCostSummaryBuilder` reduces records into `CostSummary`.
- `LocalUsageCostCache` stores an account-scoped 30-day summary.
- `UsageStore+Cost` coordinates cached and asynchronous local cost.
- `CostSectionView` renders metrics and a fixed 30-day chart.
- `MenuBarPreferencesController` persists the optional remaining percentage.
- `SettingsWindowController` provides the established reusable native-window
  pattern for an accessory app.

The scanner already contains critical correctness behavior:

- Codex cumulative token deltas;
- Claude request/message deduplication;
- separate cache-read and cache-write token fields;
- account-scoped roots;
- captured-account exclusion;
- symlink-resolved root deduplication;
- dynamic and bundled pricing coverage.

The new design must preserve these rules.

## Architectural decisions

### Separate analysis from provider snapshots

Do not expand `UsageSnapshot` into a general historical analytics container.
Live quota and local history have different freshness, provenance, and account
scope.

Add local insights state beside snapshots:

```swift
public struct UsageInsightsScopeKey: Codable, Hashable, Sendable {
  public var provider: UsageProvider
  public var accountScopeID: String
}

@MainActor
@Observable
final class UsageStore {
  private(set) var localInsights: [UsageInsightsScopeKey: UsageInsightsSummary] = [:]
  private(set) var localInsightStates:
    [UsageInsightsScopeKey: UsageInsightsLoadState] = [:]
}
```

The scope key uses an opaque stable logical scope identifier, not an email,
credential path, or access token. Exact scope is reserved for logs that carry a
provider-stable account identity. Codex and Claude credential directories can
retain history across account switches, so their current file ownership is
validated but their history remains one shared root scope. Provider-only keys
are insufficient because different configured roots may be displayed at the
same time.

The existing `snapshot.cost` path remains during migration so current provider
reported and local fallback behavior does not regress.

### Scan once, derive multiple presentations

Refactor the local estimator around one structured analysis:

```swift
public protocol UsageInsightsAnalyzing: Sendable {
  func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary?

  func insights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> UsageInsightsSummary?

  func invalidate(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  )
}
```

`LocalUsageCostEstimator` can temporarily derive a `CostSummary` from
`UsageInsightsSummary`. This prevents a second scan and keeps existing tests
useful while call sites migrate. The adapter carries the selected metric's
`UsageMetricLimitation` so the legacy cost UI cannot present a partial
unsupported or shared-scope value as exact.

The legacy app path must preserve scan semantics instead of collapsing every
missing number to `nil`:

```swift
public enum UsageCostRefreshOutcome: Equatable, Sendable {
  case updated(CostSummary)
  case confirmedEmpty
  case unavailable
}
```

`UsageStore` clears local presentation only for `confirmedEmpty`. It preserves
the last valid same-scope value for `unavailable`, which includes transient
read failures, unsupported replacements, and cancellation. Preservation is
limited to a summary whose final daily bucket matches the current local
calendar day; yesterday's `Today` value is cleared at the day boundary.

### Availability is typed, not inferred from zero

Optional metrics need a reason:

```swift
public enum UsageMetricAvailability: Codable, Equatable, Sendable {
  case available
  case partial(UsageMetricLimitation)
  case unavailable(UsageMetricLimitation)
}

public enum UsageMetricLimitation: String, Codable, Sendable {
  case noActivity
  case noLocalLogs
  case unknownAccountScope
  case sharedAccountScope
  case unsupportedTokenFields
  case unstableSessionIdentity
  case missingPricing
  case stalePricing
  case scanFailed
}

public enum UsageMetric<Value>: Codable, Equatable, Sendable
where Value: Codable & Equatable & Sendable {
  case available(Value)
  case partial(value: Value, limitation: UsageMetricLimitation)
  case unavailable(UsageMetricLimitation)
}
```

The enum makes it impossible to construct `available` without a value or
`unavailable` with one. `partial` retains a usable value with its limitation.
Do not model unknown input tokens as `0`.

## Domain model

Proposed public models:

```swift
public struct UsageInsightsSummary: Codable, Equatable, Sendable {
  public var scopeKey: UsageInsightsScopeKey
  public var generatedAt: Date
  public var source: UsageInsightsSource
  public var accountScope: UsageInsightsAccountScope
  public var sourceDescription: String
  public var daily: [DailyUsageInsight]

  public func period(_ period: UsageInsightsPeriod) -> UsageInsightsPeriodSummary?
}

public struct DailyUsageInsight: Codable, Equatable, Identifiable, Sendable {
  public var date: Date
  public var spend: UsageMetric<Double>
  public var tokens: UsageTokenBreakdown
  public var sessionCount: UsageMetric<Int>
  public var models: [ModelUsageInsight]
  public var pricingCoverage: CostEstimateCoverage
  public var id: Date { date }
}

public struct UsageInsightsPeriodSummary: Equatable, Sendable {
  public var startDate: Date
  public var endDate: Date
  public var spend: UsageMetric<Double>
  public var tokens: UsageTokenBreakdown
  public var models: [ModelUsageInsight]
  public var sessionCount: UsageMetric<Int>
  public var cacheEfficiency: UsageMetric<Double>
  public var pricingCoverage: CostEstimateCoverage
  public var daily: [DailyUsageInsight]
}

public struct UsageTokenBreakdown: Codable, Equatable, Sendable {
  public var input: UsageMetric<Int>
  public var output: UsageMetric<Int>
  public var cacheRead: UsageMetric<Int>
  public var cacheWrite: UsageMetric<Int>
  public var total: UsageMetric<Int>
}

public struct ModelUsageInsight: Codable, Equatable, Identifiable, Sendable {
  public var modelID: String
  public var spend: UsageMetric<Double>
  public var tokens: UsageTokenBreakdown
  public var id: String { modelID }
}
```

`UsageInsightsSource` describes the provider-specific local log source.
Provider-reported cost remains on the legacy `CostSummary` path and does not
produce detailed insights. `UsageInsightsAccountScope` distinguishes exact,
and shared local cache scopes; an unavailable scope produces no numeric
summary. Neither type contains a raw credential path.

The cache keeps only hashed session identities inside daily buckets so a 7-day
slice can deduplicate sessions that cross midnight. Those internal keys never
expose or persist a raw file path.

### Aggregation rules

- Build all requested periods from one 30-day summary.
- Calendar boundaries use the user's current local calendar consistently.
- Seven- and 30-day slices contain exactly that many consecutive local calendar
  buckets ending today, including explicit zero-activity buckets after a
  successful scan.
- Period totals, top model, cache efficiency, and sessions use the same selected
  date range.
- `Today` is the final local-calendar day, not the last non-empty day.
- The average rule divides by all displayed calendar buckets, including today
  and zero-activity days.
- Presentation prefers spend when it is available or partial, and falls back to
  trustworthy total tokens when spend is unavailable. The chart, average, and
  headline values switch together.
- Top model sorts by available or partial spend, then available total tokens,
  then model ID for deterministic ties.
- Cache efficiency is `cacheRead / (input + cacheRead)` only when both values are
  trustworthy.
- Pricing coverage is computed from priced and unpriced tokens, never inferred
  from a nonzero spend.
- A successful empty scan produces an explicit no-activity summary.
- A failed or unscoped scan produces no numeric summary.
- Mixed supported and unsupported sessions retain every stable session
  identity and mark token and spend totals as partial.

### Provider-specific rules

#### Codex

- Preserve cumulative-delta precedence over per-row token fields.
- Keep cached input excluded from non-cached input.
- Use session identity only when stable across duplicate streaming rows.

#### Claude

- Preserve request/message deduplication.
- Do not treat placeholder input or output counts as real usage.
- Cache efficiency remains unavailable without a trustworthy input
  denominator.
- Credential-file, keychain, and environment roots remain shared and visibly
  not-account-specific unless records gain a tested stable account identity.
- Captured registry accounts do not inherit the active CLI's logs.

## Cache design

Introduce a versioned insights cache rather than silently decoding an expanded
`CostSummary`:

```text
~/Library/Caches/Quotari/LocalUsageInsights/
  v1-<provider>-<historyDays>-<scopeHash>.json
```

The entry stores:

- schema version;
- generated timestamp;
- history window;
- hashed account scope ID;
- structured insights summary.

Migration behavior:

1. Read the new insights cache first.
2. If absent, the existing cost cache may still populate the legacy cost UI,
   but only under the same resolved shared-root scope key.
3. Recalculate insights asynchronously.
4. Delete an invalid new cache entry rather than guessing a migration.
5. Keep existing cost cache files until every cost call site has migrated.

Shared-root keys are derived from a stable canonical root family, while scans
read only the currently effective members of that family. Root deletion and
recreation therefore cannot switch back to an older cache key. Symlinks,
reordered Claude root lists, automatic selection, and a credential file
resolving to the same family address the same cache. Claude Desktop's discovered
project leaves map to their stable session-container family. One atomic,
fingerprint-only file per alias keeps a symlink-backed family's resolved
identity stable if the link temporarily disappears without letting concurrent
estimators overwrite another alias. Resolution and writes for the same alias
are serialized within the process, and raw paths are never persisted.

Insights and legacy adapter writes share a per-scope generation coordinator.
Invalidation advances the generation and removes both cache representations
under the same lock; an older in-flight analysis cannot recreate either cache
after that boundary.

No raw log line, prompt, response, full path, access token, email, or shell
command is cached.

## Local log change monitor

### Ownership

Add a `LocalUsageChangeMonitor` service in the app target because it follows
application and account-selection lifecycle. Keep root resolution and event
models in `QuotariCore`.

```swift
protocol LocalUsageChangeMonitoring: Sendable {
  func events(
    for scopes: [LocalUsageWatchScope]
  ) -> AsyncStream<LocalUsageChange>
}

struct LocalUsageWatchScope: Hashable, Sendable {
  var key: UsageInsightsScopeKey
  var roots: [URL]
}
```

The production implementation wraps macOS file-system events. The test
implementation yields deterministic events without touching a real home
directory.

Registrations cover each enabled provider's selected dashboard scope plus a
different Analytics scope while that window is open. Closing Analytics removes
its additional registration. Identical roots remain deduplicated even when two
consumers request the same scope.

### Event policy

- Observe only roots that exist and belong to an effective local scope.
- Canonicalize paths with symlink resolution before registration.
- Filter for relevant session-log file types.
- Treat create, write, rename, and delete as invalidating changes.
- Coalesce ordinary bursts for approximately two seconds.
- If at least three relevant events arrive in ten seconds, extend the quiet
  period up to approximately 30 seconds.
- Emit one change per affected provider and scope.
- Rebuild registrations after account discovery, selected-account changes, CLI
  account switches, provider activation changes, or root changes.
- Remove an Analytics-only registration when its window closes.

### Refresh coordination

`UsageStore` owns one cancellable insight task per `UsageInsightsScopeKey`:

1. Receive an affected scope.
2. Verify the scope is still selected by the dashboard or focused Analytics
   context.
3. Invalidate only that provider and scope cache.
4. Cancel or supersede older work with scope revision and generation IDs.
5. Analyze off the main actor.
6. Apply only if provider, account scope, revision, and generation still match.
7. Preserve the last valid summary on cancellation or transient failure.

The existing 15-minute scan throttle remains for timer-driven refresh. A
file-system event bypasses that time throttle after coalescing because it is
evidence that the underlying data changed.

## Menu-bar design

### Preferences

Replace the Boolean with:

```swift
enum MenuBarMetric: String, Codable, Sendable {
  case hidden
  case remainingQuota
  case todayCost
}
```

Preserve independent quota and cost source choices:

```swift
struct MenuBarMetricPreferences: Codable, Sendable {
  var metric: MenuBarMetric
  var quotaSource: MenuBarUsageSource
  var costSource: UsageProvider?
}
```

`quotaSource` keeps the current `Most constrained` or provider behavior.
`costSource` accepts only an explicit provider. The Settings UI changes from a
toggle to a `Metric` picker and conditionally shows `Quota source` or `Cost
source`. An unset cost source renders a `Choose a cost source` validation
message and produces no menu-bar value.

### Migration

Update `MenuBarPreferences.init(from:)` to decode the new fields when present,
then fall back to the legacy Boolean. The legacy `usageSource` becomes
`quotaSource`; `costSource` starts as `nil`. Continue writing the existing
defaults key so users retain their mascot and quota source preferences.

### Presentation

Add a single `menuBarMetricText` computed property and keep the label view
presentation-only.

- Remaining quota keeps the current fixed-width percentage behavior.
- Today cost resolves the selected provider's current dashboard account to a
  `UsageInsightsScopeKey` and reads only its successful local `Today` bucket.
- Provider-reported period cost and credits are never used as today's cost.
- A cached or newly scanned value remains usable only when its scope and local
  calendar day match the refresh completion clock. A scan that crosses local
  midnight cannot install or retain the previous day's value; return `nil`
  until the new day's scoped scan succeeds.
- Today cost uses localized currency in an intrinsic label capped at 64 points;
  values that exceed the cap use compact currency notation rather than
  truncation.
- Partial estimates use an approximation prefix.
- Unavailable values return `nil`.
- A missing or disabled `costSource` stays unavailable; it never falls back to
  `Most constrained` or another provider.
- Accessibility describes the provider and coverage without relying on the
  approximation glyph.

## Popover design

### Component hierarchy

```text
ProviderCardView
  ProviderHeader
  QuotaWindowSection
  UsageInsightsDisclosure
    CollapsedUsageSummary
    UsageInsightsSection
      UsageInsightsHeader
      UsageInsightMetrics
      UsageTrendChart
      UsageInsightCells
      UsageCoverageLabel
      OpenAnalyticsButton
```

`DashboardContent` owns the optional expanded provider ID so no more than one
Usage Insights section is expanded. With one enabled provider it expands that
provider; with multiple providers it expands the first provider with scoped
local insights. The value is dashboard-lifetime state and is not persisted.

Each `ProviderCardView` owns its selected insights period as `@State` and passes
it as a binding to both the collapsed summary and expanded section. Collapsing a
card therefore does not reset its period.

`UsageInsightsSection` receives immutable values, the period binding, and an
explicit `openAnalytics` action. Aggregation and formatting do not run in
`body`. Its selected-period label is derived from the same period value used to
slice totals, chart data, and cells.

The section should remain useful when some metrics are unavailable:

- hide unavailable cells;
- switch the complete headline/chart unit from cost to total tokens when pricing
  is unavailable but token totals are trustworthy;
- use an adaptive one-to-three-column `Grid`;
- truncate long model names;
- retain full model names in help and accessibility text;
- keep the chart height stable while cached data refreshes.

A provider-reported-only `CostSummary` takes a separate compact legacy row. It
does not instantiate `UsageInsightsSection` and cannot open Analytics.

### View states

Represent the section with one state enum:

```swift
enum UsageInsightsLoadState: Equatable {
  case idle
  case loading(cached: UsageInsightsSummary?)
  case loaded(UsageInsightsSummary)
  case empty(UsageInsightsEmptyReason)
  case failed(previous: UsageInsightsSummary?, message: String)
}
```

Avoid separate `isLoading`, `hasError`, and `hasData` flags.

## Analytics window design

### Presentation

Add `AnalyticsWindowController`, following `SettingsWindowController`:

- one retained `NSWindow`;
- identifier `Quotari.Analytics`;
- title `Usage Analytics`;
- resizable and closable;
- initial content size approximately 840 × 620 points;
- minimum content size approximately 680 × 480 points;
- activate the accessory app and bring the existing window forward;
- update the focused provider and account when opened again.

The popover dismisses before the Analytics window becomes key.

### State ownership

`AnalyticsRootView` receives `UsageStore` through the environment because it is
an app-wide service. It owns provider, account, period, and chart metric as
local value state.

`AnalyticsWindowController.show(context:)` supplies an `AnalyticsContext`
containing the originating scope key and popover period. Showing the retained
window again replaces that context. Provider or account changes inside the
window request another scope without mutating the dashboard's selected account.
The account picker lists known accounts, including saved accounts whose
unavailable state explains that no local logs can be attributed.

Do not introduce a second reference view model unless window-specific async
coordination becomes more complex than the store's existing state.

### Layout

```text
Toolbar
  Provider picker · Account context · Period picker

ScrollView
  Summary metrics
  Daily trend chart
  Token category summary
  Model breakdown
  Coverage and source disclosure
```

Use Swift Charts and small value-driven subviews. No view performs file or
network work directly. If provider or account selection changes, use
`.task(id:)` only to request store-owned loading, with cancellation treated as
normal.

## Localization

Every user-facing string routes through `L10n.string` and
`Localizable.xcstrings`. Add Korean translations in the same feature change.

Dynamic labels require explicit format entries for:

- selected-period totals;
- partial estimate accessibility;
- source and account scope;
- no-activity and unavailable reasons;
- chart day summaries.

Tests must not rely on the machine's preferred language.

## Testing strategy

### Core tests

- per-day and per-model aggregation;
- `UsageMetric` value and availability invariants;
- 7-day slicing from a 30-day summary;
- local calendar boundaries;
- deterministic top-model ties;
- cache efficiency availability;
- Claude placeholder-token rejection;
- Codex cumulative delta behavior;
- duplicate request/message suppression;
- exact, shared, captured, and unknown account scopes;
- successful zero activity versus failed scan;
- versioned cache isolation and invalidation.

### Change monitor tests

- create, write, rename, and delete event mapping;
- irrelevant extension filtering;
- canonical and symlinked root deduplication;
- normal and sustained-burst coalescing;
- provider-specific invalidation;
- simultaneous dashboard and Analytics scopes for the same provider;
- account-switch reconfiguration;
- cancellation and stale-generation rejection;
- disabled-provider behavior.

### Store tests

- cached insights appear before async refresh;
- log events bypass timer throttle;
- transient failure keeps previous insights;
- provider or account changes prevent stale application;
- summaries and tasks for two accounts of one provider never collide;
- local analysis never delays live quota;
- captured accounts never inherit active CLI insights.

### UI tests and snapshots

Add deterministic previews and snapshots for:

- loaded 7-day and 30-day popover;
- complete and partial pricing;
- token fallback when pricing is unavailable;
- no activity;
- unavailable account scope;
- refreshing with cached data;
- English and Korean layouts;
- one and two enabled providers;
- multi-provider accordion expansion and keyboard traversal;
- Analytics window loaded, partial, and empty states;
- menu-bar hidden, remaining quota, complete cost, partial cost, and unavailable
  cost.

Snapshots use isolated defaults, fixture accounts, and a stub analyzer. They
must never read live credentials, local session logs, caches, or network state.

## Performance and lifecycle guardrails

- Parsing and aggregation stay off the main actor.
- SwiftUI receives immutable, stable-ID aggregates.
- Event bursts produce one analysis task per affected scope.
- A provider card does not aggregate arrays in `body`.
- Analytics uses lazy containers for unbounded model lists.
- No observer, stream, or task survives `UsageStore` teardown in tests.
- Add a representative parser benchmark before setting a numeric latency
  budget.

## Privacy and security

- No new network request.
- No raw session content is persisted or transmitted.
- No credential, token, email, prompt, response, full path, or shell argument
  is added to logs.
- Cache file names use the existing stable hash approach for scope IDs.
- Debug descriptions redact raw roots and account identifiers.
- Project and tool analytics remain out of scope until a separate privacy
  review.

## Implementation slices

Each slice should be independently reviewable and keep tests with behavior:

1. Structured insights domain model and aggregation
2. Versioned cache and legacy cost adapter
3. Local log change monitor and refresh coordination
4. Menu-bar metric preference migration and today-cost display
5. Compact Usage Insights popover section
6. Analytics window and presentation controller
7. Localization, accessibility, snapshots, and release documentation

The slices may be stacked, but provider parsing and account-attribution
correctness must land below presentation changes that depend on them.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Claude placeholders create false cache metrics | Typed availability and provider rules |
| Logs belong to another account | Provider-plus-scope keys preserve attribution rules |
| File events cause repeated full scans | Provider-scoped coalescing and generation cancellation |
| Popover becomes too dense | Stable 300-point layout and separate Analytics window |
| Preference migration resets user choices | Legacy Boolean decoding tests |
| Partial pricing appears exact | Approximation marker and coverage disclosure |
| New caches conflict with legacy cost | Versioned parallel cache and adapter |
| SwiftUI views own background lifecycle | Store and injected service ownership |

## Definition of done

- Product success criteria are covered by tests or documented visual checks.
- Full test suite passes.
- SwiftFormat and strict SwiftLint pass.
- English and Korean popover snapshots fit the existing bounds.
- Packaged Settings and Analytics window smoke checks pass.
- Packaged resources and Sparkle checks remain unaffected.
- No real account, credential, session log, or machine-global defaults are used
  by tests.

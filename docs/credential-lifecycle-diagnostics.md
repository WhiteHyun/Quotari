# Credential lifecycle diagnostics

Quotari records a local structured timeline for saved-account monitoring, OAuth refresh, persistence,
CLI account switching, and the delayed post-switch validation. This is diagnostic evidence only: it does
not change when or how tokens are refreshed.

## Storage and retention

- File: `~/Library/Application Support/Quotari/Diagnostics/CredentialLifecycle.jsonl`
- Retention: the newest 21 days, capped at 5 MB
- Permissions: `0600` for the JSONL and salt files, `0700` for the diagnostics directory
- Access: Settings → About → Reveal Diagnostic Log…

Every line is an independently decodable JSON event. Malformed and expired lines are discarded during
startup and daily maintenance, before the log is revealed, and during append-time compaction. When the
size cap is crossed, the oldest complete events are removed until the file is at most 80% full so normal
appends do not rewrite the entire log on every event.

## Privacy boundary

Allowed fields are limited to event type, provider, source category, interaction type, predefined reason
or failure category, timestamp, and aggregate monitored/eligible counts. Account correlation uses a
truncated SHA-256 digest with a random installation-local salt.

The log must never contain access or refresh tokens, provider account IDs, registry IDs, email addresses,
credential fingerprints, keychain labels, filesystem paths, request or response bodies, prompts, or raw
error descriptions. Do not add arbitrary metadata or string-valued error fields to
`CredentialLifecycleEvent`.

## Incident reading order

For a long-unused saved account, follow its opaque `accountID` through:

1. `monitoringPass` and `validationStarted`
2. `refreshSelected` and `refreshStarted`, when expiry or an unauthorized response requires exchange
3. `refreshSucceeded` followed by `persistenceSucceeded`, or a typed failure/deferred event
4. `switchStarted`, `switchCredentialsWritten`, and `switchVerified`
5. `postSwitchRefreshScheduled`, `postSwitchRefreshStarted`, and `postSwitchRefreshCompleted`

`reauthenticationRequired` is the diagnostic equivalent of an invalid or revoked refresh grant. A usable
saved credential for the same account can restore an expired CLI slot; if every copy is rejected, the
account must be logged in and saved again.

## Automatic Claude CLI recovery

While Claude monitoring is enabled, account reloads check for expired or empty CLI credentials before
normal usage requests. Recovery requires exactly one unexpired, renewable saved account with verified
account and organization IDs matching Claude's existing `oauthAccount`. Nonempty live credentials also
require a cached profile bound to their exact access token; terminal labels alone cannot prove ownership.

Recovery waits until Claude exits, drains Quotari's credential requests, and reuses the switch installer's
process checks, slot verification, and rollback. It preserves unrelated credential fields and does not
follow the dashboard selection. Healthy credentials, ambiguous saved accounts, pending token grants,
unreadable stores, and logout with a removed terminal identity are left unchanged. Saved-only monitoring
continues checking on later refreshes so recovery can resume after Claude exits or the saved token renews.

`automaticCLIRecoverySucceeded` identifies a completed local installation, correlated with the saved
account. It does not establish server acceptance or a successful Claude launch. `automaticCLIRecoveryFailed`
records typed read/write/concurrency failures; an active CLI is silently deferred until a later pass.

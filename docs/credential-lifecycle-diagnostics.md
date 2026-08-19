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
compaction, and the oldest complete events are removed first when the size cap is reached.

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

`reauthenticationRequired` is the diagnostic equivalent of an invalid or revoked refresh grant. Quotari
cannot repair that state; the affected CLI account must be logged in and saved again.

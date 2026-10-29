# Never spend quota or rotate accounts automatically

Quotari observes provider quota and leaves every action that changes it to the
user. It shows Codex rate-limit reset credits but offers no way to redeem one.
When the active account runs low, an opt-in notification (off by default) may
suggest a monitored saved account with recent live data, but Quotari never
switches on its own. Redeeming a credit spends a scarce resource. Automatic
rotation between subscription accounts raises provider-terms questions and can
race an active CLI session's credential refresh. Both therefore stay behind an
explicit user action that goes through the existing switch interlocks.

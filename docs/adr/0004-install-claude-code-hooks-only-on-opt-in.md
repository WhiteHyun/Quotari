# Install Claude Code hooks only on opt-in

Session activity alerts ("needs input" and "finished") require adding hook
entries to the user's `~/.claude/settings.json`, a file Quotari otherwise never
writes. Quotari installs the hooks only when the user turns the feature on. It
merges them without touching other entries and removes them cleanly when the
feature is turned off, and the hooks never involve credentials. Without hooks, a
session count from process detection still works.

When Codex hooks are supported the same way, their payloads include prompt and
response text. Quotari discards that text on receipt and never stores it.

The installed hook runs the packaged `quotari hook`. It keeps only the event
kind, session ID, and working-directory name from the payload and passes them
to the running app as a distributed notification. Like the rest of the CLI, it
reads no credentials, and it writes no files. With the app closed, the event is
dropped.

# Share usage with other tools through a snapshot file, not a local server

Other tools read Quotari's latest live usage from a versioned JSON snapshot file
that the app writes to Application Support. A `quotari` CLI only reads that
file. It never reads or refreshes credentials, so the app stays the single
credential owner and no second process can race its token refresh. The file
contains no tokens or account emails.

A loopback HTTP API and an MCP server were rejected for now because they would
add a long-lived listening surface for data that a file serves equally well.

`quotari statusline` prints a line that users wire into Claude Code themselves.
Quotari does not claim Claude Code's single statusline slot. It also does not
ingest the `rate_limits` that the statusline receives, because the CLI never
writes.

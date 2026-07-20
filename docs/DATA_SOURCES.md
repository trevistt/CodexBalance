# Data Sources

## Quota source order

1. OAuth: reads only the ChatGPT OAuth access token from the Codex-owned
   `auth.json` in `CODEX_HOME` or the standard local Codex directory and sends
   it to the reviewed usage endpoint. Redirects are rejected. An OpenAI API
   key is not valid for this endpoint and is never used as a substitute.
2. CLI RPC: starts the local Codex CLI in app-server mode and reads the account
   rate-limit response. It does not open an interactive login flow.
3. Session logs: scans recent local Codex JSONL records for complete rate-limit
   windows.

The first complete source wins. Codex Balance does not combine a Session window
from one source with a Weekly window from another.

If the auth file contains only an API key, the OAuth source fails closed and
the resolver may continue to the credential-free local CLI/session sources.

These are implementation-level integrations, not a promise of a stable public
quota API. Source formats may change with Codex releases.

## Local analytics

The analytics scanner reads local Codex session JSONL and SQLite state metadata
to derive token totals, recent work, model mix, histograms, and partial cost
estimates. Complete records are parsed temporarily in memory; prompt/message
text and raw records are not retained. SQLite thread totals can be cumulative,
so the UI labels partial/estimated values rather than presenting billing truth.

The built-in price table is intentionally narrow and dated. Unknown model
families return unavailable. Estimates do not represent subscription billing,
discounts, taxes, credits, or every cache/long-context rule.

## Writes

App-owned snapshots, observations, analytics indexes, preferences, and logs use
the `CodexBalance` namespace. Provider credentials and Codex source records are
read-only.

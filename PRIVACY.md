# Privacy

Codex Balance runs locally and has no project-operated backend or telemetry.

## Data read

- Codex-owned OAuth data for a direct quota request
- Codex CLI app-server quota output as a fallback
- local Codex session records and state metadata for read-only analytics

The analytics scanner temporarily parses complete local JSON records in
memory so it can extract timestamps, model names, token counters, and usage
windows. It does not persist prompts, messages, raw records, account emails,
tokens, cookies, or credential JSON. Its cache contains aggregate metadata.

## Data written

The app writes only its own caches and preferences under the `CodexBalance`
namespace. Local launch scripts may write logs under `~/Library/Logs/CodexBalance`.
Open at Login is opt-in and uses `app.codexbalance.local`.

## Network

Live OAuth quota refreshes connect directly to the reviewed OpenAI endpoint.
No analytics data is sent to a Codex Balance server because no such server
exists.

## Estimates

Token and cost analytics can be incomplete or stale. Cost estimates use a
dated built-in table for recognized models and exclude subscription treatment,
discounts, and other billing adjustments. Unknown models return unavailable.

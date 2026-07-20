# Troubleshooting

## The app does not start

Run `Scripts/package_app.sh`, then inspect `Scripts/status_signing.sh` and the
local launcher log under `~/Library/Logs/CodexBalance`.

## Quota is unavailable

Confirm the Codex CLI is installed and signed in. The OAuth auth file must be a
regular owner-owned file with mode `0600`; symlinks, hard links, broad modes,
and oversized files are rejected. Codex Balance does not repair credentials or
open a background login prompt.

## Local analytics is empty

Local records may not exist yet, may use an unsupported shape, or may fall
outside the selected history window. Analytics is optional and does not block
quota display.

## Keychain prompt appears

Unsigned or ad-hoc builds can receive a different macOS code identity between
builds. If macOS requires owner action for protected data, stop the app and
review the build/signing path. Do not automate the dialog or change Keychain
ACLs. A stable Developer ID signature and notarization are recommended for any
future official binary distribution.

## Reset local app state

Quit the app, then inspect the `CodexBalance` cache/preferences paths described
in [Architecture](ARCHITECTURE.md). Do not delete provider-owned Codex files.

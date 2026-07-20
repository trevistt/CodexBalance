# Security Policy

## Supported version

Security fixes target the latest source on `main`.

## Reporting

Use GitHub Private Vulnerability Reporting when available. Do not post tokens,
auth JSON, private paths, account identifiers, raw logs, or exploit details in
a public issue.

## Security boundaries

- ChatGPT OAuth credentials remain in the Codex-owned local auth file and are
  read only from an owner-only regular file with no symlink following;
- OpenAI API keys are never treated as ChatGPT OAuth tokens or sent to the
  ChatGPT quota endpoint;
- bearer requests are restricted to the reviewed usage endpoint and redirects
  are rejected;
- the app does not write credentials, refresh tokens, browser cookies, or
  Keychain ACLs;
- fixtures and CI do not use live accounts, Keychain, browser state, or Open at
  Login;
- diagnostics redact bearer values and local paths.

This source release is not a penetration test or a signed/notarized binary
distribution. Review local code and signing state before running it.

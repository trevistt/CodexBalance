# Development

## Local checks

```sh
sh -n Scripts/*.sh
swift build
swift test
Scripts/test.sh
Scripts/apple_material_uiux_contract.sh
Scripts/package_app.sh
dist/CodexBalance.app/Contents/MacOS/CodexBalance --smoke-check
Scripts/status_signing.sh
Scripts/public_safety_scan.sh
```

`Scripts/test.sh` is the deterministic assertion harness and must print a
positive assertion count. `swift test` is also required, but only count it as
executed-test proof when its output contains a test-run summary; some
Command Line Tools combinations build and link the Swift Testing target
without printing executed assertions.

## Fixtures

Visual fixtures use synthetic snapshots and render in memory. Example:

```sh
dist/CodexBalance.app/Contents/MacOS/CodexBalance \
  --visual-qa-fixture:session-weekly docs/assets/overview-dark.png
```

The packaged AppKit/Accessibility driver exercises hover/click, scrolling,
Refresh feedback, Pin/Unpin, keyboard paths, light/dark content and constrained
height using an isolated nonce fixture. Evidence output belongs in a private
temporary directory and must never be committed.

Display QA options are accepted only with a valid nonce fixture. Use
`--ui-qa-appearance=light` or `dark`, and optionally a bounded
`--ui-qa-panel-max-height=540`. Production launches reject these QA display
arguments when no isolated fixture is present.

## Signing

The package script defaults to ad-hoc signing. macOS may ask for Keychain
access when an unsigned/ad-hoc build's identity changes and it attempts to read
another app's protected item. Codex Balance does not automate those prompts,
change ACLs, or copy credentials. Official binary distribution would require a
stable Developer ID signature and notarization; neither is part of this source
release.

## Open at Login

First package the app. To inspect a candidate plist without installing it:

```sh
CODEX_BALANCE_OPEN_AT_LOGIN_PLIST_OUTPUT=/tmp/app.codexbalance.local.plist \
  Scripts/install_open_at_login.sh
```

Run the installer without the output override only when you explicitly want to
install the local user service. CI never runs installer, status, launcher, or
uninstaller scripts.

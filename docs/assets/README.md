# Visual Fixtures

These PNG files are deterministic product fixtures rendered in memory by the
packaged `CodexBalance` executable. They use synthetic quota and local activity
values. They do not capture the desktop, read credentials, or contain real
account data.

| File | Fixture variant |
| --- | --- |
| `overview-dark.png` | `session-weekly` |
| `overview-light.png` | `backdrop-light` |
| `weekly-only.png` | `weekly-only` |
| `details-expanded.png` | `details-expanded` |
| `loading.png` | `loading` |
| `no-local-data.png` | `analytics-unavailable` |
| `stale.png` | `stale` |
| `error.png` | `error` |
| `constrained.png` | `constrained` |
| `increase-contrast.png` | `increase-contrast` |
| `reduce-transparency.png` | `reduce-transparency` |

Generate a fixture after running `Scripts/package_app.sh`:

```sh
dist/CodexBalance.app/Contents/MacOS/CodexBalance \
  --visual-qa-fixture:session-weekly docs/assets/overview-dark.png
```

The launch-candidate renderer used for these files was source version `0.1.0`
and had SHA-256
`2decb584150dc7c7928e288cd8b8450ccb73039433aa91f2b9f028c7ba0b61b7`.

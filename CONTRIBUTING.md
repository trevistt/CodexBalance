# Contributing

Contributions are welcome through GitHub issues and pull requests.

1. Keep changes focused and credential-free.
2. Use synthetic fixtures; never attach account data, auth files, live logs,
   private paths, or real quota screenshots.
3. Run `swift build`, `swift test`, `Scripts/test.sh`, shell syntax checks,
   packaging, smoke checks, and `Scripts/public_safety_scan.sh`.
4. Describe user-visible behavior, validation, privacy impact, and limitations
   in the pull request.

Do not add network services, credential storage, background login prompts,
browser scraping, or new production dependencies without prior design and
security review.

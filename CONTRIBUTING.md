# Contributing

Thanks for your interest! This is a small, self-contained Bash tool. A few
constraints keep it portable and safe.

## Ground rules

- **Bash 3.2 / macOS-safe.** It runs on the stock macOS system bash (3.2), so no
  bash-4+ features (no associative arrays, `${x^^}`, `mapfile`, …). CI runs the
  suite under both bash 5 and a `bash:3.2` container.
- **shellcheck-clean.** `shellcheck auto-review.sh` must pass with no warnings.
- **Tests required.** A behaviour change needs a test in
  `tests/auto-review.bats`. `gh` and the model call are mocked at the process
  boundary — no network, no model, and no tokens are needed to run the suite.
- **The output contract is load-bearing.** A review is `VERDICT: green|yellow|red`
  on its own line, then a markdown body with `## ` sections. `is_valid_review`,
  `parse_verdict`, and `parse_body` must stay in sync.
- **Don't weaken the guardrails** documented in `CLAUDE.md` / `SECURITY.md`
  (never merge, fork → digest, agentic is read-only, prompt-injection fencing,
  secrets only in the env wrapper).

## Running the tests

```bash
# needs: bats, jq, shellcheck
shellcheck auto-review.sh
bats tests/auto-review.bats

# bash 3.2 leg (matches CI):
docker run --rm -v "$PWD":/code -w /code bash:3.2 \
  sh -c 'apk add --no-cache bats jq git >/dev/null && bats tests/'
```

## Pull requests

Keep commits atomic, with messages in
[Conventional Commits](https://www.conventionalcommits.org/) style (`feat:`,
`fix:`, `docs:`, `test:`, `refactor:`, `chore:`). Open a PR; CI (shellcheck + the
suite on bash 5 and bash 3.2) must be green before merge.

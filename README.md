# pr-review-bot — headless PR pre-reviewer (`claude -p`)

A small, self-contained, **generic** automation that runs `claude -p` against
open pull requests of one or more **target repositories** and posts an **English
pre-review comment** via `gh`. It runs on a self-hosted box (e.g. a Mac mini) on
a schedule.

It is repo-agnostic: point it at any repo with `GH_REPO`, or list several in
`repos.conf` and let it rotate. It lives outside the repos it reviews (no
coupling, no self-review recursion) and **self-manages a disposable clone** per
target for its deep-review mode — you never point it at a working copy.

> **It is a *pre*-review aid, not a gate.** It never approves and never merges —
> a human reviewer makes the final call. The posted comment is clearly labelled
> as an automated pre-review.

## How it works

The script does **all deterministic work** so the model only has to judge —
fewer tokens, reproducible, and debuggable without the model:

1. **Pick a target.** Either an explicit `GH_REPO`, or — in rotation mode — the
   next repo from `repos.conf` (see [Rotation](#rotation-staggering-many-repos)).
2. **Fetch** PR metadata, CI status, changed files, and the diff via `gh`.
3. **Dedup** on the head commit SHA (a hidden marker in a prior comment) — a PR
   is only re-reviewed when new commits land. `FORCE=1` overrides.
4. **Route** by author + changed-file paths (zero tokens) to pick mode + model:

   | PR touches | Mode | Model |
   | --- | --- | --- |
   | bot author (`*[bot]`, dependabot) | `digest` | Haiku |
   | docs / config / styling only | `digest` | Haiku |
   | general code (`.ts/.py/.go/.rs/.sql/…`) | `digest` | Sonnet |
   | security-sensitive (`auth`/`login`/`crypto`/`secret`/`token`/migrations/`Dockerfile`/CI/`payment`/`webhook`) | `agentic` | Opus |

   The heuristics are generic and language-agnostic; edit `route()` to taste.

5. **Review**:
   - `digest` — a pre-built bundle (diff + CI status) is piped to a sandboxed
     `claude -p` with no tools. Cheap, fixed cost.
   - `agentic` — the PR branch is checked out and the model reads across the repo
     (`Read`/`Grep`/`Glob`) to verify the diff against the real code. Optionally
     uses review subagents named in `SUBAGENTS`. Reserved for sensitive changes.
6. **Validate** — the output is hard-checked against the contract (below) before
   anything is posted. On a violation it retries once with a corrective hint; if
   it still doesn't conform, nothing is posted and it's logged. Since no marker
   is written, the next scheduled run retries automatically (self-healing).
7. **Post** — the validated output is wrapped with a hidden marker + bot banner
   and posted with `gh pr comment`.

### Output contract

The model's stdout is:

```
VERDICT: green|yellow|red

## Summary
...
```

This is **validated before posting**: the first non-blank line must be exactly
`VERDICT: green|yellow|red` and the body must contain at least one `## ` section.
Non-conforming output is retried once, then skipped (never posted). The script
then wraps the body and prepends a hidden HTML marker that is invisible in the
rendered comment but drives **dedup**, **verdict routing**, and **logging**:

```
<!-- auto-review v1 | repo=owner/name | pr=128 | sha=abc123def456 | verdict=yellow | model=claude-haiku-4-5 | mode=digest | domains=deps -->
```

The reviewer persona lives in `reviewer-prompt.md` — it is a generic
senior-engineer review prompt. Edit it, or point `PROMPT_FILE` at a custom one
per target if you want repo-specific lenses.

## Usage

```bash
# Explicit single repo — poll all its open PRs (bot PRs first)
GH_REPO=owner/name ./auto-review.sh

# Explicit single repo — review specific PRs only
GH_REPO=owner/name ./auto-review.sh 128 130

# Rotation: review the NEXT repo from repos.conf (one per run, round-robin)
./auto-review.sh

# Rotation: review EVERY repo in repos.conf in one run (catch-up / testing)
ALL=1 ./auto-review.sh

# Preview without posting (prints the comment it would post)
GH_REPO=owner/name DRY_RUN=1 ./auto-review.sh 128

# Force a re-review even if this head commit was already reviewed
GH_REPO=owner/name FORCE=1 ./auto-review.sh 128
```

### Rotation: staggering many repos

To watch several repos without hammering them all at once, list them in
`repos.conf` (copy `repos.conf.example`):

```
owner/repo-a
owner/repo-b
owner/repo-c
```

With no `GH_REPO`, each run reviews **one** repo and advances a persistent
round-robin cursor (`$STATE_DIR/cursor`). On a 15-minute timer that staggers
them: `repo-a` now, `repo-b` in 15 min, `repo-c` in 30, then back to `repo-a` —
so each repo is checked every `N × 15` min. Add/remove repos any time; the
cursor wraps over the current length.

### Env knobs

| Var | Default | Purpose |
| --- | --- | --- |
| `GH_REPO` | _(unset)_ | explicit single target `owner/name` (overrides rotation) |
| `REPOS_FILE` | `./repos.conf` | rotation list, one `owner/name` per line |
| `ALL` | `0` | rotation mode: review every listed repo this run |
| `SUBAGENTS` | _(unset)_ | space-separated review subagent names for agentic mode |
| `PROMPT_FILE` | `./reviewer-prompt.md` | reviewer persona (override per target) |
| `REPO_DIR` | `$STATE_DIR/checkout/<owner__repo>` | self-managed disposable clone (agentic) |
| `MODEL_CHEAP` / `MODEL_MID` / `MODEL_DEEP` | haiku / sonnet / opus | per-route models |
| `MAX_DIFF_LINES` | `2000` | diff cap fed to the model |
| `CLAUDE_TIMEOUT` | `600` | hard per-call timeout (needs `timeout`/`gtimeout`) |
| `STATE_DIR` | `$XDG_STATE_HOME/pr-review-bot` | lock + logs + cursor + clones |
| `BOT_LOGIN` | _(unset)_ | if set, dedup only trusts comments by this account |
| `DRY_RUN` | `0` | print instead of post |
| `FORCE` | `0` | ignore dedup |

## Auth (unattended box)

- **Claude:** run `claude setup-token` once to mint a long-lived token, then set
  `CLAUDE_CODE_OAUTH_TOKEN` (uses your existing plan, no per-call API billing).
  Alternatively set `ANTHROPIC_API_KEY` (pay-per-use).
- **GitHub:** prefer a **fine-grained token scoped to only the target repos**,
  with *Pull requests: read & write* (for comments) and *Contents: read* —
  **not** the broad classic `repo` scope. The runner checks out PR branches and
  runs tools against them; keep the blast radius of a compromised runner minimal.

> ⚠️ The rendered `~/Library/LaunchAgents/com.pr-review-bot.plist` holds these
> tokens in cleartext. Never commit it; `chmod 600` it. Only the `.example` (with
> placeholders) lives in the repo.

## Schedule (launchd)

```bash
cp com.pr-review-bot.plist.example \
   ~/Library/LaunchAgents/com.pr-review-bot.plist
# replace __HOME__, __BOT_DIR__, __CLAUDE_CODE_OAUTH_TOKEN__, __GH_TOKEN__
launchctl load -w ~/Library/LaunchAgents/com.pr-review-bot.plist
```

Runs every 15 min; the script single-flight-locks so runs never overlap.
Logs: `$STATE_DIR/auto-review.log` plus the launchd std{out,err} logs.

## Guardrails (deliberate)

- **Never approves, never merges** — comment-only. The verdict drives the
  comment (and optionally labels), nothing else.
- **Posts as a bot pre-review**, clearly banner-labelled, so it can't be mistaken
  for a human approval.
- **English, no internal tool/agent names** in the public comment.
- **Cost is gated by risk** — only security-sensitive touchpoints get the
  expensive agentic pass; the routine majority runs cheap.
- **Fork PRs never get checked out.** A cross-repository (fork) PR is
  attacker-controlled, so it is forced to the no-tools digest pass regardless of
  the paths it touches. Agentic mode (which checks out the branch) only ever
  runs on same-repo branches — i.e. authors who can already push to the repo.
- **Agentic mode is read-only by construction:** no `Bash` (so a hostile
  `.gitattributes`/`.git/config` diff driver can't run code), no `acceptEdits`,
  and `Write`/`Edit` are not in the tool allowlist. The diff is fed via the
  pre-built bundle; `Read`/`Grep`/`Glob` verify against the checked-out tree.
- **Untrusted content is fenced** in the bundle and the persona forbids following
  instructions embedded in PR text (prompt-injection resistance).
- **Prompt-injection residual:** in digest mode the model has no tools, so the
  worst case is a mislabelled comment a human still reads. `BOT_LOGIN` hardens
  dedup against a PR author spoofing the skip-marker.

### Operational notes

- **The target checkout is self-managed.** On the first agentic run the bot
  clones each target into `$STATE_DIR/checkout/<owner__repo>` and reuses it
  thereafter (`gh pr checkout --force` per PR). Do not point `REPO_DIR` at your
  interactive working clone — agentic mode mutates it in place and never restores
  your branch. The dedicated clone also bounds the damage if a checked-out branch
  ever turns out to be hostile.
- **Stale lock:** the single-flight lock is a `mkdir` under `$STATE_DIR/.lock`.
  A `SIGKILL`/power-loss mid-run can orphan it, which silently disables the
  reviewer. If runs stop happening, `rmdir "$STATE_DIR/.lock"`.
- **Timeout dependency:** the hard per-call timeout needs `timeout` or `gtimeout`
  (`brew install coreutils`). Without it the script logs a warning and runs with
  no timeout.

# CLAUDE.md — pr-review-bot

## What this is

A generic, self-hosted **headless PR pre-reviewer**. A single Bash script
(`auto-review.sh`) runs `claude -p` against open pull requests of one or more
target repositories and posts an English pre-review comment via the `gh` CLI.
**Comment-only by default**: it never merges, and never approves/requests-changes
unless a repo opts into "gate" mode (see Security posture) — a human makes the
final call. Designed to run unattended on a Mac mini via `launchd`.

Not a product/library: there is no build, no dependencies to install. The only
runtime requirements are `claude`, `gh`, `jq`, `git`, and (for the timeout
guard) `timeout`/`gtimeout`.

## Files

- `auto-review.sh` — the whole tool (config → route → review → validate → post).
- `reviewer-prompt.md` — the reviewer persona / system prompt. Generic
  senior-engineer review prompt; tune lenses here, or override per target with
  `PROMPT_FILE`.
- `repos.conf.example` — template for the rotation target list (`repos.conf` is
  gitignored).
- `com.pr-review-bot.plist.example` — launchd agent template.
- `README.md` — user-facing setup + usage.
- (runtime) `$STATE_DIR/archive/<owner__repo>/pr<n>-<sha>-<ts>.md` — per-review
  debug session: decision, exact model input, raw output (incl. retries),
  validation, inline anchoring, what was posted. Written for failures too. The
  thing you hand back to `cc` to debug a review.

## Design (don't regress these)

- **The script does all deterministic work** (target selection, `gh` fetch, CI
  status, path routing, diff assembly, dedup, output validation) so the model
  only has to judge. Keep token-spend predictable and the flow debuggable
  without invoking the model.
- **Two modes**, chosen per-PR by `route()` from author + changed paths (zero
  tokens): `digest` (bundle piped to a sandboxed `claude -p`, NO tools) and
  `agentic` (checks out the branch, `Read`/`Grep`/`Glob` only). Any same-repo
  code change defaults to `agentic` so the model can verify references the diff
  alone can't (out-of-delta callers, shared helpers); docs/dep-bumps and **all
  fork PRs** stay on `digest`. Model per risk: Haiku (bot/docs) / Sonnet (code) /
  Opus (security-sensitive).
- **Output contract:** the model must emit `VERDICT: green|yellow|red`, a blank
  line, then a markdown body with `## ` sections. `is_valid_review()` HARD-
  validates this before posting; on failure it retries once with a corrective
  hint, then skips (no marker written → next run retries). Never post
  unvalidated/fallback text as if it were a real review.
- **Rotation:** with no `GH_REPO`, each run reviews ONE repo from `repos.conf`
  and advances a persistent round-robin cursor (`$STATE_DIR/cursor`) — this is
  the deliberate stagger so a 15-min timer doesn't hit all repos at once.
- **Inline comments (agentic only):** the model may append an
  `@@INLINE@@ … @@END_INLINE@@` JSON array of `{path,line,body}`. Each entry is
  **anchor-validated against the diff** (`valid_anchors`) before posting —
  off-diff entries are dropped, never sent, because GitHub 422s the whole review
  otherwise. Posted as one Reviews-API review with `event:"COMMENT"` (summary as
  body + inline comments); summary-only mode uses `gh pr comment`.

## Security posture (these are load-bearing — preserve them)

- **Never merge.** No `gh pr merge`, ever — a human owns the merge; the bot only
  reviews.
- **Comment-only is the DEFAULT.** Out of the box the verdict drives a COMMENT
  review / issue comment — never `APPROVE`/`REQUEST_CHANGES`. An opt-in, per-repo
  **gate** mode (`REVIEW_ACTIONS=gate`, or a `repos.conf` 3rd column) maps the
  verdict to a review event: green→`APPROVE`, red→blocking `REQUEST_CHANGES`,
  **yellow→`COMMENT`** (advises but does not block — a yellow is often a concern
  the model can't fully verify, so blocking on it trapped PRs in a re-review
  loop). Gate mode is OFF unless explicitly enabled for a repo, and a
  typo'd value fails safe to `comment`. Even in gate mode a fork (cross-repository)
  PR is **never auto-APPROVEd** — it downgrades to `COMMENT` (don't rubber-stamp
  untrusted external code). Note: an enabled `APPROVE` can satisfy branch-protection
  approval counts, so a repo needing human sign-off must require a human/CODEOWNERS
  approval in branch protection — that is the operator's responsibility, not the bot's.
- **Inline comments are anchor-validated against the diff** before posting; never
  post model-supplied line numbers unchecked (off-diff lines 422 the review).
- **Fork PRs are never checked out** — a cross-repository PR is forced to the
  no-tools digest mode. Agentic mode only runs on same-repo (trusted) branches.
- **Agentic mode is read-only by construction:** allowlist is `Read Grep Glob
  Task` only — NO `Bash` (a hostile `.gitattributes`/`.git/config` diff driver
  could otherwise run code), NO `--permission-mode acceptEdits`, no `Write`/
  `Edit`. The diff is fed via the bundle.
- **PR ids are integer-validated** before flowing into shell/instruction.
- **Untrusted PR content is fenced** as DATA in the bundle; the persona forbids
  following instructions embedded in PR text. Dedup matches the full marker
  prefix (and optionally a trusted `BOT_LOGIN`) to resist skip-marker spoofing.
- **Incremental review reads untrusted author content.** On re-review it feeds
  the author's PR responses to the model as memory — these stay inside the fenced
  DATA block (never the trusted preamble), and the instruction tells the model to
  treat a point as resolved only when the diff actually shows the fix (verify, not
  obey) and never to change its verdict on PR-content instruction. The delta is the
  GitHub compare API (`base...head`), used only for a clean fast-forward; a
  rebase/force-push (diverged) or first review falls back to a full review. The
  prior base SHA is read by matching the FULL bot-marker prefix (not a bare
  `sha=`), so PR content can't inject a base; and because a wrong base in gate mode
  could hide commits from an auto-APPROVE, **incremental gating requires `BOT_LOGIN`**
  (gate + unset BOT_LOGIN → full review).
- **Tokens/secrets** live only in the launchd env; never log or post them. Use a
  fine-grained `GH_TOKEN` scoped to the target repos, not classic `repo`.

## Conventions

- **All code/comments/commits/docs in English.** Conventional Commits.
- **Bash must stay POSIX-bash-3.2 compatible** (macOS system bash): no
  `mapfile`, no namerefs (`local -n`). Use `while read` + process substitution,
  global arrays.
- **`shellcheck` must be clean** before committing (`shellcheck auto-review.sh`).
- The script guards `main` behind `BASH_SOURCE`/`$0` so it can be **sourced for
  testing**: `source ./auto-review.sh` then call `route`, `is_valid_review`,
  `load_repos`, `next_cursor` directly (set a temp `STATE_DIR` first).
- Verify changes with: `shellcheck`, `bash -n`, the sourced unit tests, and a
  `DRY_RUN=1 GH_REPO=owner/name ./auto-review.sh <pr>` end-to-end (posts nothing).

## Guardrails for changes

Touching auth/checkout/tool-allowlist/posting paths, or the route/validate
logic, is security-relevant — re-reason the threat model (untrusted PR content,
untrusted checked-out branch) before changing it, and keep the guarantees above.

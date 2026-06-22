#!/usr/bin/env bats
#
# Unit + integration tests for auto-review.sh.
#
# The script is sourced (its `BASH_SOURCE == $0` guard means preflight + main run
# only when it is EXECUTED, so sourcing is side-effect-free: no lock, no tool
# checks, no filesystem writes). Network/model calls are mocked by overriding the
# `gh` and `run_claude` functions — function definitions shadow PATH commands.
#
# Sourcing the script also turns on `set -euo pipefail` in the test shell. NOTE:
# bash exempts a non-final `[[ ]]` from set -e, so a false `[[ ]]` that is not the
# last command would silently NOT fail the test. Assert substrings via the
# has()/lacks() helpers below (case-based, `return 1` on mismatch — a simple
# command that DOES abort under set -e wherever it sits). Single-bracket `[ ]`
# exact checks and bats `run` (for a command whose non-zero exit is under test)
# are fine as-is.

setup() {
  AR="$BATS_TEST_DIRNAME/../auto-review.sh"
  STATE_DIR="$(mktemp -d)"
  export STATE_DIR
  # shellcheck disable=SC1090
  source "$AR"
  # Dynamic-scope context that record_usage / run_claude_review read from their
  # caller (review_pr/route set these in the real run).
  GH_REPO="owner/repo"; pr=1; MODE="digest"; MODEL="test-model"
  echo "input" > "$LAST_INPUT_FILE"   # run_claude_review reads its stdin from here
  : > "$STATE_DIR/prior"              # prior bot comments for dedup (empty = none)
}

teardown() {
  [ -n "$STATE_DIR" ] && rm -rf "$STATE_DIR"
}

# Default gh stub for the review_pr tests: PR metadata from $STATE_DIR/meta.json,
# prior review comments (for dedup) from $STATE_DIR/prior, canned CI + diff. Each
# test writes only what it varies (its meta.json / prior / run_claude). Tests that
# need different gh behaviour redefine gh() locally.
gh() {
  case "$1 $2" in
    "pr view")
      if [[ "$*" == *"comments,reviews"* ]]; then cat "$STATE_DIR/prior"
      else cat "$STATE_DIR/meta.json"; fi ;;
    "pr checks")   echo "(no checks reported)" ;;
    "pr diff")     printf '%s\n' 'diff --git a/src/util.ts b/src/util.ts' '@@ -1 +1,2 @@' '+const x = 1;' ;;
    "pr checkout") : ;;                  # agentic checkout (stubbed; no network)
    "pr comment")  echo "SHOULD-NOT-POST-IN-DRY-RUN" >&2; return 1 ;;
    "repo clone")  mkdir -p "$4/.git" ;; # agentic clone (stubbed; $4 = target dir)
    *) echo "UNHANDLED gh $*" >&2; return 1 ;;
  esac
}

# git stub for agentic mode: review_agentic's checkout subshell runs
# `git config`/`git fetch` and verifies `git rev-parse HEAD` == the PR head.
# Return the head straight from the meta fixture so the checkout always
# "matches" — no network, no real clone. Code PRs now route agentic by default,
# so most review_pr e2e tests flow through this.
git() {
  case "$1" in
    config|fetch) : ;;
    rev-parse)    jq -r '.headRefOid' "$STATE_DIR/meta.json" ;;
    *)            command git "$@" ;;
  esac
}

# Substring assertions that stay load-bearing regardless of position. A bare
# `[[ $x == *needle* ]]` is exempt from set -e when it is not the last command,
# so a false one mid-body would not fail the test; these `return 1` on mismatch
# (a simple command, which set -e honours anywhere in the body).
has()   { case "$2" in *"$1"*) return 0 ;; *) printf 'assert has: missing >>%s<<\n' "$1" >&2; return 1 ;; esac; }
lacks() { case "$2" in *"$1"*) printf 'assert lacks: unexpected >>%s<<\n' "$1" >&2; return 1 ;; *) return 0 ;; esac; }

# ── route() ──────────────────────────────────────────────────────────────────

@test "route: dependabot author → digest/cheap/deps" {
  route "app/dependabot" "package.json"
  [ "$MODE" = digest ]
  [ "$MODEL" = "$MODEL_CHEAP" ]
  [ "$DOMAINS" = deps ]
}

@test "route: [bot] author → deps (cheapest path)" {
  route "renovate[bot]" "yarn.lock"
  [ "$DOMAINS" = deps ]
  [ "$MODEL" = "$MODEL_CHEAP" ]
}

@test "route: auth path → agentic/deep/sensitive" {
  route "alice" "src/auth/login.ts"
  [ "$MODE" = agentic ]
  [ "$MODEL" = "$MODEL_DEEP" ]
  [ "$DOMAINS" = sensitive ]
}

@test "route: migrations dir → agentic/sensitive" {
  route "alice" "backend/db/migrations/0001_init.sql"
  [ "$MODE" = agentic ]
  [ "$DOMAINS" = sensitive ]
}

@test "route: Dockerfile → agentic/sensitive" {
  route "alice" "Dockerfile"
  [ "$MODE" = agentic ]
}

@test "route: plain code (.ts) → agentic/mid/code (repo-aware, can verify out-of-delta refs)" {
  route "alice" "src/util.ts"
  [ "$MODE" = agentic ]
  [ "$MODEL" = "$MODEL_MID" ]
  [ "$DOMAINS" = code ]
}

@test "route: docs only → digest/cheap/docs" {
  route "alice" "README.md"
  [ "$DOMAINS" = docs ]
  [ "$MODEL" = "$MODEL_CHEAP" ]
}

@test "route: 'auth' as a non-boundary substring does NOT trigger sensitive" {
  # authentication.ts: 'auth' is not followed by a [._/-] boundary or end.
  route "alice" "src/authoritative.ts"
  [ "$DOMAINS" = code ]
}

# ── parse_verdict / is_valid_review / parse_body ─────────────────────────────

@test "parse_verdict: extracts the colour" {
  run parse_verdict <<<$'VERDICT: red\n\n## Summary\nx'
  [ "$status" -eq 0 ]
  [ "$output" = "red" ]
}

@test "parse_verdict: skips a decoy line, picks the real verdict" {
  run parse_verdict <<<$'VERDICT: not sure, maybe red\nVERDICT: yellow\n\n## S\nx'
  [ "$output" = "yellow" ]
}

@test "parse_verdict: case-insensitive" {
  run parse_verdict <<<$'verdict: GREEN\n\n## S'
  [ "$output" = "green" ]
}

@test "is_valid_review: accepts verdict + heading" {
  run is_valid_review <<<$'VERDICT: green\n\n## Summary\nok'
  [ "$status" -eq 0 ]
}

@test "is_valid_review: tolerates a preamble before VERDICT" {
  run is_valid_review <<<$'Let me verify the diff first.\nDone.\nVERDICT: red\n\n## Findings\n- x'
  [ "$status" -eq 0 ]
}

@test "is_valid_review: rejects missing heading" {
  run is_valid_review <<<$'VERDICT: green\n\njust prose, no section heading'
  [ "$status" -ne 0 ]
}

@test "is_valid_review: rejects missing verdict" {
  run is_valid_review <<<$'## Summary\nno verdict line here'
  [ "$status" -ne 0 ]
}

@test "parse_body: cuts everything before the verdict line" {
  run parse_body <<<$'preamble noise\nVERDICT: green\n\n## Summary\nthe body'
  [ "$status" -eq 0 ]
  has "## Summary" "$output"
  lacks "preamble" "$output"
}

# ── record_usage() ───────────────────────────────────────────────────────────

@test "record_usage: formats figures from a valid envelope" {
  record_usage '{"is_error":false,"total_cost_usd":0.04,"num_turns":2,"duration_ms":99,"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}'
  run cat "$LAST_USAGE_FILE"
  [ "$output" = "in=10 out=20 cache_w=3 cache_r=4 cost_usd=0.04 turns=2 api_ms=99" ]
}

@test "record_usage: missing fields default to 0" {
  record_usage '{"is_error":false}'
  run cat "$LAST_USAGE_FILE"
  [ "$output" = "in=0 out=0 cache_w=0 cache_r=0 cost_usd=0 turns=0 api_ms=0" ]
}

@test "record_usage: non-JSON input → (usage unavailable)" {
  record_usage "this is not json at all"
  run cat "$LAST_USAGE_FILE"
  [ "$output" = "(usage unavailable)" ]
}

@test "record_usage: empty input → (usage unavailable)" {
  record_usage ""
  run cat "$LAST_USAGE_FILE"
  [ "$output" = "(usage unavailable)" ]
}

# ── run_claude_review() — model envelope handling ────────────────────────────

@test "run_claude_review: success emits .result and records real usage" {
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: green\n\n## S\nok","total_cost_usd":0.01,"num_turns":1,"duration_ms":5,"usage":{"input_tokens":7,"output_tokens":8,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  out="$(run_claude_review -p)"
  run is_valid_review <<<"$out"
  [ "$status" -eq 0 ]
  has "in=7 out=8 " "$(cat "$LAST_USAGE_FILE")"
}

@test "run_claude_review: is_error envelope is NOT emitted as a review (but its cost IS recorded)" {
  # The error .result embeds a fake VERDICT/## heading: without the .is_error gate
  # jq would extract it and it WOULD validate as a review — so this proves the gate.
  run_claude() { printf '%s' '{"is_error":true,"result":"oops\nVERDICT: green\n## x","total_cost_usd":0.5,"num_turns":9,"duration_ms":1,"usage":{"input_tokens":5,"output_tokens":6,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  out="$(run_claude_review -p)"
  run is_valid_review <<<"$out"
  [ "$status" -ne 0 ]
  has "cost_usd=0.5" "$(cat "$LAST_USAGE_FILE")"
}

@test "run_claude_review: empty output (timeout) → not a review, usage unavailable" {
  run_claude() { printf ''; }
  out="$(run_claude_review -p)"
  run is_valid_review <<<"$out"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAST_USAGE_FILE")" = "(usage unavailable)" ]
}

# ── effective_filter() ───────────────────────────────────────────────────────

@test "effective_filter: absent → global REVIEW_REQUESTED default" {
  REVIEW_REQUESTED="@me"
  [ "$(effective_filter "")" = "@me" ]
}

@test "effective_filter: * → empty (review every open PR)" {
  [ "$(effective_filter "*")" = "" ]
}

@test "effective_filter: all → empty" {
  [ "$(effective_filter "all")" = "" ]
}

@test "effective_filter: explicit login passes through" {
  [ "$(effective_filter "octocat")" = "octocat" ]
}

# ── load_repos() ─────────────────────────────────────────────────────────────

@test "load_repos: parses repos + per-repo filters, skips comments/blanks" {
  REPOS_FILE="$STATE_DIR/repos.conf"
  printf '%s\n' '# header comment' '' 'owner/a   @me' 'owner/b   *   # inline comment' 'owner/c' > "$REPOS_FILE"
  load_repos
  [ "${#REPOS[@]}" -eq 3 ]
  [ "${REPOS[0]}" = "owner/a" ];  [ "${REPO_FILTERS[0]}" = "@me" ]
  [ "${REPOS[1]}" = "owner/b" ];  [ "${REPO_FILTERS[1]}" = "*" ]
  [ "${REPOS[2]}" = "owner/c" ];  [ "${REPO_FILTERS[2]}" = "" ]
}

@test "load_repos: tolerates CRLF line endings" {
  REPOS_FILE="$STATE_DIR/repos.conf"
  printf 'owner/a   @me\r\nowner/b\r\n' > "$REPOS_FILE"
  load_repos
  [ "${REPOS[0]}" = "owner/a" ]
  [ "${REPO_FILTERS[0]}" = "@me" ]
  [ "${REPOS[1]}" = "owner/b" ]
}

@test "load_repos: missing file → empty list, no error" {
  REPOS_FILE="$STATE_DIR/does-not-exist.conf"
  load_repos
  [ "${#REPOS[@]}" -eq 0 ]
}

@test "load_repos: survives set -e with a trailing comment-only line (EOF regression)" {
  # A bare `load_repos` under `set -e` must not inherit the trailing read's
  # non-zero EOF status and kill the caller. Run in a fresh set -e shell.
  cat > "$STATE_DIR/r.conf" <<'EOF'
owner/a   @me
# trailing comment-only line
EOF
  run bash -c "set -euo pipefail; source '$AR'; REPOS_FILE='$STATE_DIR/r.conf'; load_repos; echo rc=\$?"
  [ "$status" -eq 0 ]
  has "rc=0" "$output"
}

# ── next_cursor() ────────────────────────────────────────────────────────────

@test "next_cursor: round-robin wraps over n" {
  rm -f "$CURSOR"
  [ "$(next_cursor 3)" = "0" ]
  [ "$(next_cursor 3)" = "1" ]
  [ "$(next_cursor 3)" = "2" ]
  [ "$(next_cursor 3)" = "0" ]
}

@test "next_cursor: a corrupt cursor file resets to 0" {
  printf 'garbage' > "$CURSOR"
  [ "$(next_cursor 2)" = "0" ]
}

# ── inline-comment helpers ───────────────────────────────────────────────────

@test "extract_inline / strip_inline: pull and remove the sentinel block" {
  body=$'## Summary\nfoo\n@@INLINE@@\n[{"path":"a.ts","line":3,"body":"x"}]\n@@END_INLINE@@\n'
  run extract_inline <<<"$body"
  has '"path":"a.ts"' "$output"
  out="$(strip_inline <<<"$body")"
  lacks "@@INLINE@@" "$out"
  has "## Summary" "$out"
}

@test "anchor_filter: keeps on-diff lines, drops off-diff ones" {
  # Stub the diff anchors: only a.ts:3 is commentable.
  valid_anchors() { printf 'a.ts\t3\n'; }
  json='[{"path":"a.ts","line":3,"body":"keep"},{"path":"a.ts","line":999,"body":"drop"}]'
  out="$(anchor_filter "$json")"
  [ "$(jq 'length' <<<"$out")" -eq 1 ]
  [ "$(jq -r '.[0].line' <<<"$out")" -eq 3 ]
  [ "$(jq -r '.[0].side' <<<"$out")" = "RIGHT" ]
}

# ── review_pr() — digest end-to-end (mocked gh + claude, DRY_RUN) ────────────

@test "review_pr: code PR → agentic (clone+checkout stubbed) builds a marker'd comment and posts nothing (DRY_RUN)" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":5,"title":"add helper","headRefOid":"abcdef1234567890","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":10,"deletions":2}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: yellow\n\n## Summary\nlgtm-ish\n","total_cost_usd":0.02,"num_turns":1,"duration_ms":3,"usage":{"input_tokens":2,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }

  DRY_RUN=1
  run review_pr 5
  [ "$status" -eq 0 ]
  has "DRY_RUN — would post (verdict=yellow)" "$output"
  has "<!-- auto-review v1 | repo=owner/repo | pr=5 | sha=abcdef123456" "$output"
  has "verdict=yellow" "$output"
  has "mode=agentic" "$output"
  has "full PR diff, at head" "$output"
}

@test "review_pr: agentic clone failure falls back to digest AND the marker says mode=digest (honest fallback)" {
  # A code PR routes agentic, but if the clone fails review_agentic falls back to
  # digest — the marker must then report digest, not the routed-but-unused agentic.
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":9,"title":"x","headRefOid":"9999000011112222","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  gh() {
    case "$1 $2" in
      "pr view")    if [[ "$*" == *"comments,reviews"* ]]; then cat "$STATE_DIR/prior"; else cat "$STATE_DIR/meta.json"; fi ;;
      "pr checks")  echo "(no checks reported)" ;;
      "pr diff")    printf '%s\n' 'diff --git a/src/util.ts b/src/util.ts' '@@ -1 +1,2 @@' '+const x = 1;' ;;
      "repo clone") return 1 ;;   # clone fails → review_agentic must fall back to digest
      *) echo "UNHANDLED gh $*" >&2; return 1 ;;
    esac
  }
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: green\n\n## Summary\nok","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  DRY_RUN=1
  run review_pr 9
  [ "$status" -eq 0 ]
  has "clone failed — falling back to digest mode" "$output"
  has "mode=digest" "$output"
}

@test "review_pr: skips a draft PR" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":6,"title":"wip","headRefOid":"deadbeef00112233","author":{"login":"alice"},"isDraft":true,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  run review_pr 6
  [ "$status" -eq 0 ]
  has "draft, skip" "$output"
}

@test "review_pr: rejects a non-numeric PR id (injection guard)" {
  run review_pr '5; rm -rf /'
  [ "$status" -eq 0 ]
  has "not a numeric id" "$output"
}

@test "route: webhook path → sensitive/agentic" {
  route "alice" "src/webhook/handler.ts"
  [ "$MODE" = agentic ]
  [ "$DOMAINS" = sensitive ]
}

@test "route: crypto path → sensitive/agentic" {
  route "alice" "src/crypto.ts"
  [ "$MODE" = agentic ]
}

# ── review_pr() — fork guard, dedup, retry/self-heal ─────────────────────────

@test "review_pr: a fork (cross-repo) PR on sensitive paths is forced to digest (no agentic checkout)" {
  # The auth path would route agentic; the fork guard must downgrade it to the
  # no-checkout digest pass so attacker-controlled code is never checked out.
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":7,"title":"sketchy","headRefOid":"f00f00f00f00f00f","author":{"login":"mallory"},"isDraft":false,"state":"OPEN","isCrossRepository":true,"files":[{"path":"src/auth/login.ts","additions":5,"deletions":1}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: red\n\n## Findings\n- x","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  DRY_RUN=1
  run review_pr 7
  [ "$status" -eq 0 ]
  has "cross-repository (fork)" "$output"
  has "forcing digest" "$output"
  has "mode=digest" "$output"
}

@test "review_pr: skips when a prior comment already carries the marker for this SHA (dedup)" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":8,"title":"x","headRefOid":"abcdef123456789a","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  # Prior bot comment carrying the FULL marker prefix for this head SHA (short=12).
  echo "<!-- auto-review v1 | repo=owner/repo | pr=8 | sha=abcdef123456 | verdict=green -->" > "$STATE_DIR/prior"
  run_claude() { echo "SHOULD-NOT-CALL-THE-MODEL" >&2; return 1; }
  run review_pr 8
  [ "$status" -eq 0 ]
  has "already reviewed, skip" "$output"
}

@test "review_pr: invalid first output retries once, then posts the valid retry (self-heal)" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":9,"title":"x","headRefOid":"1111222233334444","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  : > "$STATE_DIR/calls"
  # First call: invalid (no VERDICT). Second: valid. Tracked via a byte counter.
  run_claude() {
    printf 'x' >> "$STATE_DIR/calls"
    if [ "$(wc -c < "$STATE_DIR/calls")" -eq 1 ]; then
      printf '%s' '{"is_error":false,"result":"garbage, no verdict line","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    else
      printf '%s' '{"is_error":false,"result":"VERDICT: green\n\n## Summary\nok","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    fi
  }
  DRY_RUN=1
  run review_pr 9
  [ "$status" -eq 0 ]
  has "retrying once" "$output"
  has "retry produced a valid review" "$output"
  has "would post (verdict=green)" "$output"
}

@test "review_pr: invalid output twice → skipped, nothing posted (self-heal next run)" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":10,"title":"x","headRefOid":"5555666677778888","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"still garbage, no verdict","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  DRY_RUN=1
  run review_pr 10
  [ "$status" -eq 0 ]
  has "still non-conforming after retry" "$output"
  lacks "would post" "$output"
}

# ── preflight() — runs only on exec, so it is tested via a subprocess ─────────

@test "preflight: a held lock makes a second run exit 0 without reviewing" {
  mkdir -p "$STATE_DIR"
  mkdir "$STATE_DIR/.lock"   # simulate another run already holding the lock
  run env STATE_DIR="$STATE_DIR" REPOS_FILE=/dev/null bash "$AR"
  [ "$status" -eq 0 ]
  has "another run holds the lock" "$output"
}

@test "preflight: a missing required tool is fatal (exit 1)" {
  mkdir -p "$STATE_DIR"
  # PATH has coreutils (date/tee/mkdir) but not claude/gh → the tool check fails.
  run env PATH=/usr/bin:/bin STATE_DIR="$STATE_DIR" REPOS_FILE=/dev/null bash "$AR"
  [ "$status" -eq 1 ]
  has "FATAL:" "$output"
  has "not on PATH" "$output"
}

# ── effective_actions() + repos.conf 3rd column ──────────────────────────────

@test "effective_actions: absent → global REVIEW_ACTIONS default" {
  REVIEW_ACTIONS=gate
  [ "$(effective_actions "")" = "gate" ]
}

@test "effective_actions: comment/gate pass through" {
  [ "$(effective_actions comment)" = "comment" ]
  [ "$(effective_actions gate)" = "gate" ]
}

@test "effective_actions: an unknown value falls back to comment (fail safe)" {
  [ "$(effective_actions bogus)" = "comment" ]
}

@test "load_repos: parses the optional 3rd (actions) column" {
  REPOS_FILE="$STATE_DIR/repos.conf"
  printf '%s\n' 'owner/a   @me   gate' 'owner/b   *   comment' 'owner/c' > "$REPOS_FILE"
  load_repos
  [ "${REPO_ACTIONS[0]}" = "gate" ]
  [ "${REPO_ACTIONS[1]}" = "comment" ]
  [ "${REPO_ACTIONS[2]}" = "" ]
}

# ── review_pr() — gate mode (verdict drives APPROVE / REQUEST_CHANGES) ────────

@test "gate mode: green verdict → APPROVE via the Reviews API" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":20,"title":"x","headRefOid":"aaaa111122223333","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: green\n\n## Summary\nlgtm","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  ACTIONS_MODE=gate; DRY_RUN=1
  run review_pr 20
  [ "$status" -eq 0 ]
  has "would submit APPROVE" "$output"
  has '"event": "APPROVE"' "$output"
  has "event=APPROVE" "$output"
}

@test "gate mode: red verdict → REQUEST_CHANGES via the Reviews API" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":21,"title":"x","headRefOid":"bbbb111122223333","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: red\n\n## Findings\n- bad","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  ACTIONS_MODE=gate; DRY_RUN=1
  run review_pr 21
  [ "$status" -eq 0 ]
  has "would submit REQUEST_CHANGES" "$output"
  has '"event": "REQUEST_CHANGES"' "$output"
}

@test "gate mode: yellow verdict → REQUEST_CHANGES (any concern blocks)" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":22,"title":"x","headRefOid":"cccc111122223333","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: yellow\n\n## Summary\nmeh","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  ACTIONS_MODE=gate; DRY_RUN=1
  run review_pr 22
  [ "$status" -eq 0 ]
  has "would submit REQUEST_CHANGES" "$output"
  has '"event": "REQUEST_CHANGES"' "$output"
  has "event=REQUEST_CHANGES" "$output"
}

@test "gate mode: a fork PR is never auto-APPROVEd (downgraded to COMMENT)" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":23,"title":"x","headRefOid":"dddd111122223333","author":{"login":"mallory"},"isDraft":false,"state":"OPEN","isCrossRepository":true,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: green\n\n## Summary\nlgtm","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  ACTIONS_MODE=gate; DRY_RUN=1
  run review_pr 23
  [ "$status" -eq 0 ]
  has "not auto-approving; downgrading APPROVE to COMMENT" "$output"
  lacks "would submit APPROVE" "$output"
  has "event=COMMENT" "$output"
}

@test "default (comment) mode: a green verdict does NOT approve (gate off by default)" {
  # The headline safety invariant: with no gate configured, green is COMMENT-only.
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":24,"title":"x","headRefOid":"eeee111122223333","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: green\n\n## Summary\nlgtm","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  # ACTIONS_MODE intentionally unset → review_pr falls back to comment.
  DRY_RUN=1
  run review_pr 24
  [ "$status" -eq 0 ]
  has "would post (verdict=green)" "$output"
  has "event=COMMENT" "$output"
  lacks "would submit" "$output"
}

@test "gate mode: a missing isCrossRepository fails closed (treated as fork, not auto-APPROVEd)" {
  # No isCrossRepository field at all — must NOT be treated as same-repo.
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":25,"title":"x","headRefOid":"ffff111122223333","author":{"login":"mallory"},"isDraft":false,"state":"OPEN","files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: green\n\n## Summary\nlgtm","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  ACTIONS_MODE=gate; DRY_RUN=1
  run review_pr 25
  [ "$status" -eq 0 ]
  has "not auto-approving; downgrading APPROVE to COMMENT" "$output"
  lacks "would submit APPROVE" "$output"
  has "event=COMMENT" "$output"
}

# ── incremental review (only the delta since the bot's last review, with memory) ─

@test "prepare_incremental: a fast-forward → incremental, captures prior review + author response" {
  GH_REPO="owner/repo"; pr=5; sha="def789abc0123456"; short="def789abc012"
  seen='<!-- auto-review v1 | repo=owner/repo | pr=5 | sha=abc123def456 | verdict=red | event=COMMENT -->'
  printf '%s' '{"comments":[{"createdAt":"2026-01-01T00:00:00Z","author":{"login":"bot"},"body":"<!-- auto-review v1 | repo=owner/repo | pr=5 | sha=abc123def456 | verdict=red -->\n## Findings\n- please fix X"},{"createdAt":"2026-01-02T00:00:00Z","author":{"login":"alice"},"body":"fixed X in the latest commit"}],"reviews":[],"author":{"login":"alice"}}' > "$STATE_DIR/prview.json"
  echo "ahead" > "$STATE_DIR/cmp_status"
  gh() { case "$1" in api) cat "$STATE_DIR/cmp_status" ;; pr) cat "$STATE_DIR/prview.json" ;; esac; }
  prepare_incremental
  [ "$INCREMENTAL" -eq 1 ]
  [ "$PRIOR_SHA" = "abc123def456" ]
  has "please fix X" "$(cat "$LAST_PRIOR_FILE")"
  has "fixed X in the latest commit" "$(cat "$LAST_PRIOR_FILE")"
}

@test "prepare_incremental: diverged history (rebase/force-push) → full review" {
  GH_REPO="owner/repo"; pr=5; sha="def789abc0123456"; short="def789abc012"
  seen='<!-- auto-review v1 | repo=owner/repo | pr=5 | sha=abc123def456 | verdict=red -->'
  echo "diverged" > "$STATE_DIR/cmp_status"
  gh() { case "$1" in api) cat "$STATE_DIR/cmp_status" ;; pr) echo '{}' ;; esac; }
  prepare_incremental
  [ "$INCREMENTAL" -eq 0 ]
  [ "$PRIOR_SHA" = "" ]
}

@test "prepare_incremental: no prior bot review → full review" {
  GH_REPO="owner/repo"; pr=5; sha="def789abc0123456"; short="def789abc012"
  seen=""
  prepare_incremental
  [ "$INCREMENTAL" -eq 0 ]
}

@test "prepare_incremental: toggle off → full review even with a prior" {
  GH_REPO="owner/repo"; pr=5; sha="def789abc0123456"; short="def789abc012"
  seen='<!-- auto-review v1 | repo=owner/repo | pr=5 | sha=abc123def456 | verdict=red -->'
  INCREMENTAL_REVIEW=0
  # Stub a valid "ahead" prior so the ONLY thing keeping INCREMENTAL=0 is the toggle
  # (otherwise the test would pass even if the toggle guard were removed).
  echo "ahead" > "$STATE_DIR/cmp_status"
  printf '%s' '{"comments":[],"reviews":[],"author":{"login":"alice"}}' > "$STATE_DIR/prview.json"
  gh() { case "$1" in api) cat "$STATE_DIR/cmp_status" ;; pr) cat "$STATE_DIR/prview.json" ;; esac; }
  prepare_incremental
  [ "$INCREMENTAL" -eq 0 ]
}

@test "prepare_incremental: a bare author 'sha=' (no full bot marker) does not drive incremental (anti-spoof)" {
  GH_REPO="owner/repo"; pr=5; sha="def789abc0123456"; short="def789abc012"
  # Untrusted author text with a bare sha= token but NO full bot marker.
  seen='rebased onto sha=deadbeef1234, please re-review'
  prepare_incremental
  [ "$INCREMENTAL" -eq 0 ]
  [ "$PRIOR_SHA" = "" ]
}

@test "prepare_incremental: gate mode without BOT_LOGIN forces a full review (anti-spoof)" {
  GH_REPO="owner/repo"; pr=5; sha="def789abc0123456"; short="def789abc012"
  seen='<!-- auto-review v1 | repo=owner/repo | pr=5 | sha=abc123def456 | verdict=red -->'
  ACTIONS_MODE=gate; BOT_LOGIN=""
  # A valid "ahead" prior is stubbed; only the gate+no-BOT_LOGIN guard should keep
  # INCREMENTAL=0 (without it, the prior would drive an incremental review).
  echo "ahead" > "$STATE_DIR/cmp_status"
  printf '%s' '{"comments":[],"reviews":[],"author":{"login":"alice"}}' > "$STATE_DIR/prview.json"
  gh() { case "$1" in api) cat "$STATE_DIR/cmp_status" ;; pr) cat "$STATE_DIR/prview.json" ;; esac; }
  prepare_incremental
  [ "$INCREMENTAL" -eq 0 ]
}

@test "build_bundle: incremental mode carries the prior-review memory + only the delta diff" {
  GH_REPO="owner/repo"; pr=5; DOMAINS=code
  INCREMENTAL=1; PRIOR_SHA="abc123def456"
  printf '%s\n' "## PRIOR REVIEW you posted (on commit abc123def456)" "- author said: fixed X" > "$LAST_PRIOR_FILE"
  printf '%s\n' "diff --git a/new.ts b/new.ts" "@@ -1 +1,2 @@" "+only the new change" > "$STATE_DIR/cmp_diff"
  local meta='{"title":"t","author":{"login":"alice"},"headRefOid":"def789abc0123456","files":[{"path":"new.ts","additions":1,"deletions":0}]}'
  gh() { case "$1" in api) cat "$STATE_DIR/cmp_diff" ;; pr) echo "(no checks reported)" ;; esac; }
  out="$(build_bundle 5 "$meta")"
  has "INCREMENTAL RE-REVIEW" "$out"
  has "PRIOR REVIEW you posted" "$out"
  has "ONLY the new commits since abc123def456" "$out"
  has "+only the new change" "$out"
}

@test "build_bundle: non-incremental mode uses the full PR diff (unchanged default)" {
  GH_REPO="owner/repo"; pr=5; DOMAINS=code; INCREMENTAL=0
  local meta='{"title":"t","author":{"login":"alice"},"headRefOid":"def789abc0123456","files":[{"path":"a.ts","additions":1,"deletions":0}]}'
  gh() { case "$1 $2" in "pr checks") echo "(no checks)" ;; "pr diff") printf '%s\n' "diff --git a/a.ts b/a.ts" "+full diff line" ;; *) return 1 ;; esac; }
  out="$(build_bundle 5 "$meta")"
  has "+full diff line" "$out"
  lacks "INCREMENTAL RE-REVIEW" "$out"
  lacks "ONLY the new commits" "$out"
}

@test "review_pr: incremental end-to-end — prior marker drives a delta review + base= in the marker (DRY_RUN)" {
  cat > "$STATE_DIR/meta.json" <<'EOF'
{"number":30,"title":"x","headRefOid":"def789abc0123456","author":{"login":"alice"},"isDraft":false,"state":"OPEN","isCrossRepository":false,"files":[{"path":"src/util.ts","additions":1,"deletions":0}]}
EOF
  # A prior bot review on an OLDER commit; current head differs → not deduped.
  echo "<!-- auto-review v1 | repo=owner/repo | pr=30 | sha=abc123def456 | verdict=red | event=COMMENT -->" > "$STATE_DIR/prior"
  echo "ahead" > "$STATE_DIR/cmp_status"
  printf '%s' '{"comments":[{"createdAt":"2026-01-01T00:00:00Z","author":{"login":"bot"},"body":"<!-- auto-review v1 | repo=owner/repo | pr=30 | sha=abc123def456 | verdict=red -->\n- fix X"}],"reviews":[],"author":{"login":"alice"}}' > "$STATE_DIR/prview.json"
  printf '%s\n' "diff --git a/src/util.ts b/src/util.ts" "@@ -1 +1,2 @@" "+delta change" > "$STATE_DIR/cmp_diff"
  gh() {
    case "$1" in
      api) if [[ "$*" == *"--jq"* ]]; then cat "$STATE_DIR/cmp_status"; else cat "$STATE_DIR/cmp_diff"; fi ;;
      pr)
        case "$2" in
          view)
            if [[ "$*" == *"comments,reviews,author"* ]]; then cat "$STATE_DIR/prview.json"
            elif [[ "$*" == *"comments,reviews"* ]]; then cat "$STATE_DIR/prior"
            else cat "$STATE_DIR/meta.json"; fi ;;
          checks)   echo "(no checks reported)" ;;
          checkout) : ;;                          # agentic checkout (stubbed)
          comment)  echo "SHOULD-NOT-POST" >&2; return 1 ;;
          *) echo "UNHANDLED gh pr $2" >&2; return 1 ;;
        esac ;;
      repo) [[ "$2" == clone ]] && mkdir -p "$4/.git" ;;  # agentic clone (stubbed)
      *) echo "UNHANDLED gh $1" >&2; return 1 ;;
    esac
  }
  run_claude() { printf '%s' '{"is_error":false,"result":"VERDICT: green\n\n## Summary\nresolved","total_cost_usd":0.01,"num_turns":1,"duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'; }
  DRY_RUN=1
  run review_pr 30
  [ "$status" -eq 0 ]
  has "incremental review — only changes since abc123def456" "$output"
  has "base=abc123def456" "$output"
  has 'Scope:** incremental' "$output"
  has 'from `abc123def456` to `def789abc012`' "$output"
}

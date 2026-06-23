# Security Policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub's
**Security → Advisories → "Report a vulnerability"** on this repository, rather
than opening a public issue. Include steps to reproduce and the impact. You'll
get an acknowledgement; please allow time for a fix before public disclosure.

## Scope & threat model

This bot runs `claude -p` against pull requests and posts review comments via
`gh`. It holds a GitHub token and — optionally, in gate mode — submits
`APPROVE` / `REQUEST_CHANGES` reviews. It **never merges**. Security-relevant
properties the code is designed to preserve (see `CLAUDE.md` for the full list):

- **Never merges** — no `gh pr merge`, ever; a human owns the merge.
- **Comment-only by default** — gate mode (APPROVE/REQUEST_CHANGES) is opt-in
  per repo and still never merges. A green verdict can satisfy a branch-
  protection approval count, so require a human/CODEOWNERS approval if a person
  must sign off before merge.
- **Fork PRs are never checked out** — a cross-repository PR is forced to the
  no-tools digest pass; agentic mode (which checks out a branch) only runs on
  same-repo (trusted) branches and is read-only (no `Bash`, no edits).
- **Untrusted PR content is fenced** and the model is told never to follow
  instructions embedded in it (prompt-injection resistance); inline comments are
  anchor-validated against the diff before posting; a trusted `BOT_LOGIN`
  hardens skip-marker dedup against spoofing.
- **Secrets** (the GitHub token, the Claude credential) live only in the
  launchd/env wrapper — never in the repo, never logged or posted. `.gitignore`
  keeps the rendered plist, `repos.conf`, and `*.env` out of version control.

If you find a way to make the bot merge, approve untrusted/fork code, exfiltrate
its token, or act on injected instructions, that is in scope — please report it.

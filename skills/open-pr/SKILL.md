---
description: Push current branch, create a pull request with Greenhouse traceability. Use when opening a PR, pushing and making a PR, or shipping code.
---

# Skill: Open PR

Push the current branch and create a pull request with full Greenhouse traceability.

This skill commits, pushes, and creates the PR as a single workflow — the one exception to the "don't commit without permission" rule, because the user explicitly invoked it.

---

## Step 0: Preflight

Run Sync Queue Replay from [references/common-operations.md](../../references/common-operations.md) (check for `.claude/greenhouse-sync-queue.json`).

**Session Authentication** — run this before ANY Greenhouse API call:

```bash
eval "$(${CLAUDE_PLUGIN_ROOT}/bin/gh-jwt)"
```

`gh-jwt` ships in [plugin/bin/](../../bin/gh-jwt) and caches the session token at `~/.greenhouse/jwt`. The eval is idempotent and skips the network call when the cached token has >60s of life remaining; re-run it freely before any sequence of API calls.

All subsequent API calls use headers: `-H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"`

**Step 0 Heartbeat** — keep any running session timer alive:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/gh-heartbeat
```

`gh-heartbeat` ships in [plugin/bin/](../../bin/gh-heartbeat). It's idempotent and a no-op when no timers are running. See [Session Timer](../../references/common-operations.md#session-timer) for details.

---

## Prerequisites

- Load [references/commit-conventions.md](../../references/commit-conventions.md) for format

---

## Step 1: Run Ticket Gate

Invoke [references/ticket-gate.md](../../references/ticket-gate.md):
- If you already hold this ticket's context from the calling skill (e.g. `work-ticket` Step 8), reuse it; otherwise the gate calls `get_ticket_context`
- Identify the ticket from branch name or session context
- If no ticket → prompt to create one (can't open PR without a ticket)

Extract ticket context: ID, title, acceptance criteria, type, reviewer, compliance tags.

---

## Step 2: Pre-Flight Checks

### Verify Branch State
```bash
git branch --show-current
git status
```

Resolve `{base}` with [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch).

- Not on `{base}` or `main`
- Has commits ahead of `{base}`
- No uncommitted changes (if there are, offer to commit them)

### Run Quality Gate
Run the quality gate (see conventions). If failures → fix and re-run. Don't open a PR with failing checks.

### Check Rebase Status
```bash
git fetch origin {base}
git log --oneline HEAD..origin/{base}
```

If behind `{base}` → offer to rebase first ([Inline Rebase](../../references/common-operations.md#inline-rebase)).

---

## Step 3: Commit Staged Changes

If there are uncommitted changes:

1. Review what will be staged: `git status`
2. Check for sensitive files (`.env`, credentials, secrets) — warn and exclude if found
3. Stage changed files by name (prefer specific files over `git add -A`):
   ```bash
   git add {file1} {file2} ...
   ```
4. Commit:
   ```bash
   git commit -m "{type}: {description} [{ticket-id}]"
   ```

Determine commit type from ticket type (feature → `feat`, bug → `fix`, chore → `chore`, infrastructure → `ci`, tech_debt → `refactor`, hotfix → `hotfix`, spike → `chore`).

---

## Step 4: Push Branch

```bash
git push -u origin {branch-name}
```

If push fails (branch exists on remote with different history):
- `git push --force-with-lease origin {branch-name}`
- Never bare `--force`

---

## Step 5: Generate PR Description

Follow [templates/pr-description.md](../../templates/pr-description.md):
- `Implements {TICKET-ID}`
- What / Why / How to Verify
- Reviewer Focus areas, Test Coverage summary
- Scope decisions and the out-of-scope findings list (tickets only for items the user said yes to)

Resolve the reviewer with [conventions §Reviewer Rule](../conventions/SKILL.md#reviewer-rule) — you are the implementer, so candidates are the Team-table rows whose Greenhouse value isn't `${GREENHOUSE_TEAM_USERNAME}`. A reviewer the user already named (including one handed over by autonomous `work-ticket`) takes precedence; with several candidates and nothing named, this is the one question open-pr asks. Keep the chosen row: its Greenhouse value is the `reviewer` shown and stored, its GitHub value goes to `--reviewer`. Use your `display_name` from the directory (same section) wherever the PR text names you.

---

## Step 6: Create PR and Set Title

Two-step process because the PR number is assigned by GitHub and we want it in the title.

### Step 6a: Create the PR
```bash
gh pr create \
  --title "[{ticket-id}] {type}: {description}" \
  --body "{generated description}" \
  --reviewer "{GitHub column of the reviewer row}" \
  --base "{base}"
```

- `{base}` from [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch). A stacked branch (cut off another feature branch via a ticket dependency) names its parent branch in the session, which rung 1 picks up. When `{base}` is an epic branch, say so in the PR description.
- `{reviewer-github-username}` is the reviewer's GitHub column in the Team table. **No reviewer** → omit `--reviewer` entirely and leave the ticket's `reviewer` null.

### Step 6b: Update title with PR number
```bash
gh pr edit {number} --title "[{ticket-id}] #{number} {type}: {description}"
```

Final title format: `[RG-7] #42 feat: add password reset flow`

---

## Step 7: Update Greenhouse

Single `PATCH /rest/v1/tickets?display_id=eq.{ID}` on the ticket — every ticket write fires a realtime refetch in every open board tab, so send only fields that differ from the context you hold:
- `status` → `in_review` — omit when it already is; when sent, guard the URL with `&status=neq.in_review` (same idea as send-for-review's "already with {reviewer}" check) so a re-run writes nothing
- `pr_url` → GitHub PR URL (omit when unchanged)
- `reviewer` → the chosen row's Greenhouse value when it differs from the ticket's (omit when unchanged; `null` for no reviewer)
- `acceptance_criteria` → the ticked criteria, when the caller handed them over (work-ticket Step 8)
- `ai_implemented`, `implementation_notes` → when the caller handed them over (autonomous work-ticket)
- `updated_by` → `${GREENHOUSE_TEAM_USERNAME}` — or `"claude"` when autonomous work-ticket handed that over

Nothing differs (status already `in_review`, same PR, same reviewer, nothing handed over) → skip the PATCH entirely.

`POST /rest/v1/comments` with `{"ticket_id": "{uuid}", "org_id": "${GREENHOUSE_ORG_ID}", "author": "${GREENHOUSE_TEAM_USERNAME}", "body": "PR #{number} opened: {pr-url}. Assigned reviewer: {reviewer | none}."}` — `{reviewer}` is the Greenhouse value, never the GitHub login:

---

## Step 8: Output

```
## PR Created

**#{number}:** {title}
**URL:** {pr-url}
**Reviewer:** {reviewer | none requested}
**Greenhouse:** {display-id} (status → in_review)

### Diff Stats
{files changed, insertions, deletions}

### Next Steps
- Reviewer will be notified (when one was requested)
- CI will run automatically
- After approval → tell me to review and merge PR #{number}

💡 Want me to sync your Claude usage? I can update your token counts now.
```

---

## Error Handling

| Error | Action |
|-------|--------|
| No ticket found | Block — can't open PR without ticket |
| Quality gate fails | Fix, re-run, then proceed |
| Push rejected | Pull/rebase, resolve conflicts, re-push |
| PR already exists for branch | Show existing PR, offer to update it. Step 7 still sends only changed fields — a ticket already `in_review` with that `pr_url` gets no PATCH |
| Reviewer not found on GitHub, or the row has no GitHub value | Warn, create PR without reviewer assignment |
| No reviewer candidate | Leave `reviewer` null, warn per the Reviewer Rule, create PR without reviewer assignment |
| Greenhouse API unreachable | Create PR anyway; queue the Step 7 PATCH with `expect_status` set to the status you fetched ([Greenhouse Fallback](../../references/common-operations.md#greenhouse-fallback-git-only-mode)) |

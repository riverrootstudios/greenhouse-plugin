---
description: Squash-merge an approved PR you authored, clean up branches, and harvest the ticket in Greenhouse. Author-only — hands off if you didn't open the PR. Use when merging or landing an approved PR.
argument-hint: "[pr-number]"
---

# Skill: Merge PR

Lands an already-approved PR. Split out from `review-pr` so the **author owns the
merge** — the reviewer reviews, the author merges their own change. This skill
never reviews; it gates on approval + CI + author identity, then squash-merges,
cleans up, and harvests the ticket.

---

## Step 0: Preflight

Run Sync Queue Replay from [references/common-operations.md](../../references/common-operations.md) (check for `.claude/greenhouse-sync-queue.json`).

**Session Authentication** — run before ANY Greenhouse API call:

```bash
eval "$(${CLAUDE_PLUGIN_ROOT}/bin/gh-jwt)"
```

**Step 0 Heartbeat:**

```bash
${CLAUDE_PLUGIN_ROOT}/bin/gh-heartbeat
```

---

## Step 1: Resolve PR & Linked Ticket

**If PR number provided:**
```bash
gh pr view {number} --json title,number,author,headRefName,baseRefName,reviewDecision,mergeable,body
```

**If no PR number:** list your own open, approved PRs and pick, or ask.

Parse the PR body for `Implements {TICKET-ID}` and resolve via Resolve Ticket Context in [references/common-operations.md](../../references/common-operations.md).

---

## Step 2: Author Gate (HARD GATE)

The author lands their own PR. Ask GitHub whether you opened it — `@me` is resolved by GitHub from your `gh` auth, so no login is looked up locally:

```bash
gh pr view {number} --json author --jq .author.login     # PR author, for the message below
gh pr list --author "@me" --state open --limit 200 --json number \
  --jq 'any(.[]; .number == {number})'                   # true when you opened it
```

**If it prints `false`:** stop. Do not merge someone else's PR.

> "PR #{number} was opened by @{author}, not you. The author lands their own merge — ask @{author} to run `/greenhouse:merge-pr {number}`. I can review it instead with `/greenhouse:review-pr {number}` if that's what you meant."

**If it prints `true`:** continue.

---

## Step 3: Pre-merge Verification (HARD GATE)

Approval landing on GitHub is not the same as a green light to merge. Run every gate below first, then confirm with the user before any merge command.

**Gate — PR State:** Run the [PR State Guard](../../references/common-operations.md#pr-state-guard) — an already-merged or closed PR stops there rather than reaching the merge command. The guard is the single definition of that check; do not restate it here.

**Gate — CI on the current head:** run [CI on the Current Head](../../references/common-operations.md#ci-on-the-current-head). A `CONFLICTING` PR or a latest run whose `headSha` isn't the PR's `headRefOid` means CI is **unverified** — stop and name both SHAs and the run id; never merge on a green check from an older commit.

Then check the merge-specific requirements the guards do not cover:

```bash
gh pr view {number} --json reviewDecision,mergeable,reviews
```

- No conflicts, and carries an approving review.

**Merge conditions:** read the approving review's body. A `## Merge conditions` section (review-pr's approve-with-conditions) is listed in the confirmation below, and the yes covers them. No section → the confirmation is unchanged.

**If not approved (`reviewDecision` != `APPROVED`):**
> "PR #{number} isn't approved yet. Ask {reviewer} to run `/greenhouse:review-pr {number}` first."
Stop.

**If `reviewDecision` is `CHANGES_REQUESTED`** from a prior round that was since addressed: ensure the latest review is an approval. If branch protection still blocks on a stale changes-requested review, ask that reviewer to re-review — do NOT dismiss reviews.

**If conflicts:**
> "PR has merge conflicts. Ask me to rebase `{branch-name}` and I'll resolve them, then we can merge."
Stop.

The target branch is the PR's `baseRefName` (rung 2 of [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch)) — whatever open-pr set, including an epic branch.

With every gate passed, confirm:

> "PR #{number} is approved and CI passed on the current head ({short-sha}). Squash merge into `{target-branch}` now?"

With merge conditions, the same question lists them first:

> "PR #{number} is approved with {N} merge conditions:
> 1. {condition} ({file})
> Are these done? Yes squash-merges into `{target-branch}` now."

Wait for explicit go-ahead (`merge`, `yes`, `ship it`, `squash`, or equivalent). Anything else pauses.

```bash
gh pr merge {number} --squash --subject "{type}: {description} [{ticket-id}]"
```

Type derived from ticket type: feature → `feat`, bug → `fix`, chore → `chore`, infrastructure → `ci`, tech_debt → `refactor`, hotfix → `hotfix`, spike → `chore`.

Capture the merge commit SHA.

---

## Step 4: Branch Cleanup & Pull

First remove any worktree on the merged branch — `git branch -d` refuses a branch that a worktree still has checked out, and a stale worktree is what leaves a harvested ticket looking stuck in health-check:

```bash
git worktree list --porcelain   # find a `worktree {path}` whose `branch refs/heads/{branch-name}`
```

For each match, remove it per [common-operations §Worktrees](../../references/common-operations.md#worktrees) — confirm first, naming the path, when it has uncommitted changes. If you are standing in that worktree, move to the main checkout first.

```bash
git push origin --delete {branch-name}   # remote (if not auto-deleted)
git branch -d {branch-name}              # local
git checkout {target-branch}
git pull origin {target-branch}
```

Verify the merge commit is present: `git log --oneline -1`

---

## Step 5: Greenhouse Update

**Critical — a merged PR without a harvest update is a data integrity failure. Never skip it silently.**

`PATCH /rest/v1/tickets?display_id=eq.{ID}&status=neq.harvest` — the guard makes a re-run a no-op instead of a second write:

| Field | Value |
|-------|-------|
| `status` | `harvest` |
| `completed_at` | Current instant as a full ISO-8601 timestamp — `date -u +%Y-%m-%dT%H:%M:%SZ`. **Never a bare date:** Postgres coerces `2026-09-12` to midnight UTC, which is the previous evening in any western timezone, and every report that buckets by local day then counts the ticket a day early (GH-75 found 240 of 326 harvested tickets stamped this way, 212 landing on the wrong day) |
| `actual_complexity` | Score from what actually happened (files changed, blast radius, scope expansions — map to 1-64 using work-breakdown.md) |
| `files_changed` | Key files from the PR diff |
| `updated_by` | `${GREENHOUSE_TEAM_USERNAME}` |

`POST /rest/v1/comments` with `{"ticket_id": "{uuid}", "org_id": "${GREENHOUSE_ORG_ID}", "author": "${GREENHOUSE_TEAM_USERNAME}", "body": "Merged to {target-branch}. Squash commit: {sha}\nPR #{number} merged by ${GREENHOUSE_TEAM_USERNAME}. All acceptance criteria verified.\n\n[//]: # (gh-sync:{key})"}` — generate `{key}` (`uuidgen | tr A-Z a-z`) before the first attempt, so a timed-out POST that actually landed is recognisable on replay (see [Sync Queue Replay](../../references/common-operations.md#sync-queue-replay)).

### Error recovery

If the PATCH or comment fails with a network error, HTTP 500+, or timeout (`--retry 2` has already retried it — don't resend by hand; a 4xx is never queued, report it):

1. **Log to sync queue** (see [references/common-operations.md](../../references/common-operations.md) Greenhouse Fallback). A **timeout may have committed** the write — the queue doesn't know, so it relies on the replay guards: `expect_status` on the PATCH (the status you fetched, normally `in_review`) and the comment's `idempotency_key`:
   ```json
   [
     {
       "action": "update",
       "display_id": "{TICKET-ID}",
       "endpoint": "/rest/v1/tickets?display_id=eq.{TICKET-ID}",
       "method": "PATCH",
       "body": {"status": "harvest", "completed_at": "{iso_now}", "updated_by": "${GREENHOUSE_TEAM_USERNAME}"},
       "expect_status": "in_review",
       "attempts": 0,
       "timestamp": "{iso_now}",
       "skill": "merge-pr"
     },
     {
       "action": "comment",
       "display_id": "{TICKET-ID}",
       "ticket_id": "{uuid}",
       "endpoint": "/rest/v1/comments",
       "method": "POST",
       "body": {"ticket_id": "{uuid}", "org_id": "${GREENHOUSE_ORG_ID}", "author": "${GREENHOUSE_TEAM_USERNAME}", "body": "{same body, ending [//]: # (gh-sync:{key})}"},
       "idempotency_key": "{key}",
       "attempts": 0,
       "timestamp": "{iso_now}",
       "skill": "merge-pr"
     }
   ]
   ```
   Queue only the request(s) that failed.
3. **Warn the user explicitly:**
   > "Merged successfully but failed to update {TICKET-ID} to harvest in Greenhouse. Queued for next sync. Run `/greenhouse:health-check` to retry."

**Never report "Merged & Closed" in Step 6 without confirming the harvest update succeeded or was queued.**

### Epic Check

If the ticket belongs to an epic:
1. `GET /rest/v1/epic_progress?epic_id=eq.{uuid}`

**If epic has `epic_branch` (ticket branch merged into epic branch):**
- If all non-weeded tickets are harvested → offer the final epic PR into the integration branch (rungs 4–5 of [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch)):
  ```bash
  gh pr create --base {integration-branch} --title "[{epic-display-id}] feat: {epic-name}" --body "Closes epic {epic-display-id}. All {N} tickets complete."
  ```
- Else → report progress: *"Epic progress: {harvest_count}/{total} tickets complete in {epic-name}."*

**If no epic branch (ticket merged into the integration branch):**
- If all non-weeded tickets are harvested → `PATCH /rest/v1/epics?id=eq.{uuid}` with `{"status": "complete", "updated_by": "${GREENHOUSE_TEAM_USERNAME}"}`
- Post completion comment on ticket

---

## Step 6: Report & Next Ticket

```
## Merged & Closed

**PR:** #{number} → {target-branch}
**Commit:** {sha}
**Ticket:** {TICKET-ID} → harvest
**Branch:** {branch-name} → deleted
**Epic:** {N}/{M} tickets complete

Pick up next ticket? ({next-ticket-id}: {title}) or tell me what's next.
```

---

## Error Handling

| Error | Action |
|-------|--------|
| Runner is not the PR author | Stop, hand off to author (Step 2) |
| PR not approved | Stop, suggest `/greenhouse:review-pr` |
| CI failing | List failures, do not merge |
| CI unverified (`CONFLICTING`, or last run's `headSha` ≠ PR head) | Stop, name both SHAs and the run id, do not merge |
| Merge conditions unconfirmed | Do not merge until the author says each is done |
| Merge conflicts | Ask user to have me rebase the branch, do not merge |
| Merge blocked by stale review | Do NOT dismiss reviews. Ask original reviewer to re-review |
| Merge fails (GitHub error) | Retry once, then report. Do NOT proceed to Step 5 without a successful merge |
| Greenhouse API unreachable (Step 5) | Log to sync queue with its guards (Step 5 error recovery). Warn user explicitly. Never silently skip harvest update |
| Branch delete fails | Warn, continue — not critical |

---
description: Review a PR against acceptance criteria and post an approve or request-changes verdict. Does NOT merge — the author lands it with /greenhouse:merge-pr. Also runs read-only against your own branch with --self before you hand off. Use when reviewing a PR, self-checking a branch, or requesting changes.
argument-hint: "[pr-number] [--self]"
---

# Skill: Review PR

Structured review producing unambiguous, actionable findings. Every finding is classified as `[REQUIRED]` or `[NOTED]` — no ambiguity about what must be fixed. The gate decision flows mechanically from findings, with one reviewer choice: when every remaining `[REQUIRED]` is doc-like, approve with merge conditions (Step 3c). Designed for AI-to-AI consumption: review-pr writes findings, fix-review-feedback acts on them.

**Review and merge are separate.** This skill ends at the verdict. On approval, the PR **author** lands the change with [`/greenhouse:merge-pr`](../merge-pr/SKILL.md) — whoever reviews does not merge.

---

## Mode: `--self` (pre-handoff self-check)

When invoked with `--self` (no PR number needed), run the reviewer's evaluation against your **own current branch** before opening a PR — catch what a reviewer would flag first.

- Diff source: `git diff {base}...HEAD`, `{base}` from [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch). No PR, no `gh` calls.
- Run **Step 2** (acceptance-criteria mapping + checklist + pattern checks + classification) and produce the **Step 3b** structured output.
- **Strictly read-only:** never post to GitHub, never mutate Greenhouse, never merge. Skip Steps 1, 3c–3e entirely — including the [PR State Guard](../../references/common-operations.md#pr-state-guard), which has nothing to check when no PR exists yet.
- Frame the output as pre-handoff hygiene: "Here's what a reviewer will flag — fix before opening the PR." Then stop.

For a normal PR review (a PR number, or no args), continue below.

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

- Load [references/commit-conventions.md](../../references/commit-conventions.md) for merge commit format
- Load [references/pre-pr-checklist.md](../../references/pre-pr-checklist.md) for evaluation standards
- Load [references/review-patterns.md](../../references/review-patterns.md) (shared baseline) and the repo's `.claude/review-patterns.md` when it exists (project patterns) for known recurring issues

---

## Step 1: Resolve PR & Linked Ticket

**If PR number provided:**
```bash
gh pr view {number} --json state,isDraft,mergedAt,mergeCommit,closedAt,title,body,number,author,headRefName,headRefOid,baseRefName,files,additions,deletions,reviews,reviewDecision,statusCheckRollup,mergeable
```

**If no PR number:**
```bash
gh pr list --json number,title,author,createdAt,reviewDecision --state open
```
Pick the oldest awaiting review, or ask user.

**Gate — PR State:** Run the [PR State Guard](../../references/common-operations.md#pr-state-guard) now, before reading the diff or touching Greenhouse. A closed or merged PR stops here — an explicitly-supplied PR number is exactly the path that reaches a non-open PR (the no-number path filters to `--state open`, so it can't). Skip this gate entirely in `--self` mode.

**Gate — CI on the current head:** run [CI on the Current Head](../../references/common-operations.md#ci-on-the-current-head) — compare `headRefOid` with the latest completed run's `headSha` rather than trusting `gh pr checks`. A `CONFLICTING` PR or a SHA mismatch reports CI as **unverified** and becomes a blocking `[REQUIRED]` finding naming both SHAs and the run id — never "passing".

Parse PR description for `Implements {TICKET-ID}`. If not found, offer three options:

> "This PR doesn't reference a Greenhouse ticket. Options:
> 1. **Provide ticket ID** — if one already exists
> 2. **Create ticket now** — I'll create one from the PR context
> 3. **Skip** — proceed without ticket linkage (not recommended)"

**Option 1:** User provides ticket ID → continue normally.

**Option 2 — Create ticket now:**
```bash
curl -s -X POST "${GREENHOUSE_URL}/rest/v1/rpc/create_ticket" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "p_project_id": "{project_id from CLAUDE.md}",
    "p_title": "{derived from PR title}",
    "p_type": "{inferred from PR: feature, bug, chore, etc.}",
    "p_priority": "p2_medium",
    "p_status": "in_bloom",
    "p_assignee": "{Greenhouse value of the PR author's Team-table row}",
    "p_reviewer": "${GREENHOUSE_TEAM_USERNAME}",
    "p_created_by": "${GREENHOUSE_TEAM_USERNAME}"
  }'
```

The PR author is the implementer. Find their row by the **GitHub** column (`gh pr view {number} --json author --jq .author.login`) and store its **Greenhouse** value; no row → omit `p_assignee` and warn. You are the reviewer — a valid candidate under [conventions §Reviewer Rule](../conventions/SKILL.md#reviewer-rule), since you didn't write the code. Both values are facts about this PR, so ask nothing.
Then update the PR body to include `Implements {TICKET-ID}`:
```bash
gh pr edit {number} --body "$(gh pr view {number} --json body --jq .body)

Implements {TICKET-ID}"
```

**Option 3:** Skip — proceed with review but note the compliance gap in findings.

Resolve via Resolve Ticket Context in [references/common-operations.md](../../references/common-operations.md) — once. This one fetch serves the whole review: the acceptance criteria in Step 2, the compliance check, and the verdict PATCH.

If the ticket has compliance tags (`soc2`, `iec_62304`, `hipaa`, `pii`), invoke [references/compliance-check.md](../../references/compliance-check.md), handing it the context you just fetched.

---

## Step 2: Deep Read & Evaluate

Findings are change orders, not suggestions. Be thorough — false positives waste implementation time.

### 2a: Gather context

```bash
gh pr diff {number}
gh pr view {number} --json files
```

Read surrounding code for each changed file before flagging anything.

### 2b: Evaluate acceptance criteria

For each acceptance criterion from the Greenhouse ticket:

- **Met** — code clearly implements this criterion (note file:line)
- **Not met** — criterion cannot be mapped to code. This is always `[REQUIRED]`.

There is no middle tier. A criterion is either met or it isn't.

### 2c: Run checklist & pattern checks

Run all 7 sections of [references/pre-pr-checklist.md](../../references/pre-pr-checklist.md) — the same checklist used by `work-ticket` during self-review. Each checklist item is tagged with its severity (`[REQUIRED]` or `[NOTED]`); use those tags directly.

Check against known patterns from [references/review-patterns.md](../../references/review-patterns.md) and the repo's `.claude/review-patterns.md` — each pattern has a `Severity` field; use it.

### 2d: Classify every finding

Every finding must be tagged `[REQUIRED]` or `[NOTED]`:

| Tag | Meaning | Gate effect |
|-----|---------|-------------|
| `[REQUIRED]` | Must be fixed before approval. Includes bugs, security issues, unmet acceptance criteria, AND small consistency/cohesion fixes. **If skipping it causes codebase drift, it's required.** | Any `[REQUIRED]` → request changes |
| `[NOTED]` | True FYI only — no action to take. Reserved for: known tradeoffs, context for future work, pre-existing issues outside this PR's scope. | Does not block merge |

**When in doubt, require it.** `[NOTED]` is rare.

### 2e: Quality checks on your own findings

Before finalizing any `[REQUIRED]` finding:

1. **Verify it's actually wrong** — check if there's a reason for the pattern (a comment, a related test, a convention elsewhere in the file)
2. **Confirm the proposed fix is correct** — since `Fix:` instructions will be implemented at face value, read enough context to be confident the fix doesn't introduce new issues
3. **Scope check** — only flag issues in the PR's changed code. Pre-existing issues outside this PR's scope are `[NOTED]` at most, never `[REQUIRED]`

### 2f: Escalate findings that need human judgment

Autonomously require bug, security, and cohesion fixes. **Never unilaterally require architectural or design changes.** Escalate when:
- Architecture/design decisions
- Intent-dependent findings ("intentional or bug?")
- Scope-expanding changes (fix would significantly grow the PR)
- Conflicting patterns in the codebase

Batch escalation items and present before finalizing (see Step 3).

---

## Step 3: Escalate, Then Gate

### 3a: Present escalation items (if any)

If Step 2f identified findings needing human judgment, present them **before** finalizing the review:

```
## Findings needing your input

I found {N} items that need your call before I finalize the review:

1. **{finding title}** ({file:line})
   {description of the tradeoff or ambiguity}
   → {option A} or {option B}?

2. **{finding title}** ({file:line})
   {description}
   → {option A} or {option B}?
```

Wait for user input. Classify each item based on their answer, then proceed to 3b.

### 3b: Present structured review

```
## Review: PR #{number} — {title}

**Ticket:** {TICKET-ID}: {ticket-title}
**Files:** {count} changed (+{additions}, -{deletions})
**CI:** {passing | failing | unverified — CI last ran on {sha}, head is {sha} | pending} (from Step 1's head check)

### Acceptance Criteria
| Criterion | Status |
|-----------|--------|
| {criterion text} | Met / Not met |

### Findings

#### [REQUIRED] {finding title}
- **File:** {file:line}
- **Issue:** {what's wrong — factual, not hedged}
- **Fix:** {concrete instruction for what to change}

#### [REQUIRED] {finding title}
- **File:** {file:line}
- **Issue:** {description}
- **Fix:** {instruction}

#### [NOTED] {observation title}
- **File:** {file:line}
- **Note:** {what was observed}
- **No action needed** — {reason}

### Gate Decision
{APPROVE — no required findings / REQUEST CHANGES — {N} required findings / reviewer's choice — {N} doc-like required findings}
```

### 3c: Gate decision

- **Only `[NOTED]` findings (or none)** → approve.
- **Any code `[REQUIRED]` finding** (bugs, logic, tests, security, unmet criteria, unverified CI) → request changes. No choice is offered.
- **Every remaining `[REQUIRED]` is doc-like** — docs, code comments, copy, nothing that changes behavior → the reviewer chooses:
  > "The {N} remaining required findings are all doc-like. Request changes, or approve with them as merge conditions?"

  **Approve with merge conditions** posts an approval whose body carries the findings under a `## Merge conditions` heading, in the same `File:` / `Issue:` / `Fix:` shape. merge-pr reads that section back and asks the author to confirm each condition is done before merging. No structured tracking, no schema change.

Outside that one case the classification determines the verdict. The user's other input happened in 3a (escalation) where they helped classify ambiguous items.

### 3d: Confirm before posting (HARD GATE)

The verdict follows from the findings, but **posting it to GitHub + Greenhouse is gated on explicit user confirmation**. Do not call `gh pr review` or PATCH the ticket until the user gives a go-ahead in this exchange.

Print the verdict line and ask:

> "Ready to post **{APPROVE | APPROVE with {N} merge conditions | REQUEST_CHANGES}** for PR #{number} ({N} required, {M} noted). Post now, or walk through any section first?"

Wait for a reply. Acceptable go-aheads: `post`, `ship it`, `yes`, `approve`, `request changes`, `lgtm`, or equivalent. Anything else — questions, "walk me through X", "let me think", silence — pauses posting. Address what was asked, then re-prompt with the same question.

This gate applies whether the verdict is APPROVE or REQUEST_CHANGES. Never post a review verdict on the same turn it was drafted unless the user explicitly said to.

### 3e: Post the verdict

Only run this after explicit go-ahead in 3d.

**If approve (no required findings):**
```bash
gh pr review {number} --approve --body "Looks good! {optional notes about [NOTED] items}"
```
Then hand off to the author — this skill does not merge:
> "Approved ✅ — PR #{number} has no required findings. @{author}, run `/greenhouse:merge-pr {number}` to land it."

**If approve with merge conditions (every remaining `[REQUIRED]` doc-like, reviewer chose it in 3c):**
```bash
gh pr review {number} --approve --body "Approved with merge conditions.

## Merge conditions

#### [REQUIRED] {finding title}
- **File:** {file:line}
- **Issue:** {description}
- **Fix:** {instruction}"
```
> "Approved with {N} merge conditions — @{author}, `/greenhouse:merge-pr {number}` will list them and ask you to confirm before merging."

**If request changes (any required findings):**
```bash
gh pr review {number} --request-changes --body "{structured list of [REQUIRED] findings with File/Issue/Fix}"
```

The review body posted to GitHub MUST use the same structured `[REQUIRED]` format with `File:`, `Issue:`, and `Fix:` fields so that `fix-review-feedback` can parse it directly.

Single `PATCH /rest/v1/tickets?display_id=eq.{ID}`:
- `status` → `changes_requested`, `updated_by` → `${GREENHOUSE_TEAM_USERNAME}`

`POST /rest/v1/comments` (`author`: `${GREENHOUSE_TEAM_USERNAME}`; include `org_id` from `${GREENHOUSE_ORG_ID}` — RLS rejects the insert without it) — body is "Review completed. {N} required changes:" followed by a `[REQUIRED]` bullet for each finding, then a closing line asking the implementer to invoke `/greenhouse:fix-review-feedback` on the ticket. The body is multi-line — construct it using the temp-file + `--rawfile` pattern in [references/common-operations.md](../../references/common-operations.md) §Posting Comments and PATCHing Multi-line Ticket Fields.

Then stop. The author addresses feedback with `/greenhouse:fix-review-feedback` and re-requests review; merging happens later via `/greenhouse:merge-pr`.

---

## Error Handling

| Error | Action |
|-------|--------|
| PR doesn't reference a ticket | Offer the three options in Step 1 (provide ID / create / skip) |
| Compliance check fails (compliance-tagged ticket) | Report failures in findings as `[REQUIRED]` |
| CI failing | Note in findings; a red build is a `[REQUIRED]` finding, not a merge concern here |
| CI unverified (`CONFLICTING`, or last run's `headSha` ≠ PR head) | `[REQUIRED]` finding naming both SHAs and the run id — never report CI as passing |
| Escalation items unanswered | Wait for user input in Step 3a before finalizing |
| Greenhouse API unreachable (request-changes PATCH) | Log to sync queue with `expect_status: "in_review"` ([Greenhouse Fallback](../../references/common-operations.md#greenhouse-fallback-git-only-mode)) — `--retry 2` already retried it. Warn user explicitly |
| User asks to merge | Merging is not part of review — direct them to `/greenhouse:merge-pr {number}` (author-only) |

---
description: Start or implement a ticket. Asks whether to work interactively or autonomously based on ticket readiness. Use when starting work on a ticket, picking up a ticket, implementing autonomously, or working on something.
argument-hint: "[ticket-id or search-term]"
---

# Skill: Work Ticket

Pick up a ticket, plan, branch, and implement — interactively or autonomously based on ticket readiness.

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

- Load [references/commit-conventions.md](../../references/commit-conventions.md) for commit format
- Load [references/engineering-conventions.md](../../references/engineering-conventions.md) for architecture patterns, complexity signals, and anti-patterns

---

## Step 1: Gate & Context

### 1.1 Resolve Ticket

**Ticket ID provided (e.g., `RG-42`):**
- Resolve via Resolve Ticket Context in [references/common-operations.md](../../references/common-operations.md)

**Search term provided (e.g., "password reset"):**
- `GET /rest/v1/tickets?project_id=eq.{id}&status=not.in.(harvest,weeded)&title=ilike.*{term}*&select=display_id,title,status,complexity,assignee`
- Present matches and ask which one

**Not found:**
> "Can't find that ticket. Want me to plan some new work, or do you have the ticket ID?"

### 1.2 Confirm Status

Confirm ticket status is `sprouted` or `seeds` (not already `in_bloom`, `in_review`, or `harvest`). If already in progress, resume (see Branch step).

### 1.3 Check Blockers

Run the Blocker Check from [references/common-operations.md](../../references/common-operations.md).

### 1.4 Determine Mode

Ask the user:
> "Want me to implement this autonomously (I'll write the code, run tests, and open a PR while you do something else) or work through it with you?"

If autonomous and ticket is not tended:
> "This ticket hasn't been tended — tended tickets produce significantly better autonomous results. Want me to tend it first?"

Store the chosen mode (`interactive` or `autonomous`) for use in Steps 3, 6, 7, 8.

**Autonomous — settle the reviewer now.** The unattended run ends in `open-pr`, which must never stop on a question. Run [conventions §Reviewer Rule](../conventions/SKILL.md#reviewer-rule) here, while the user is still at the keyboard: with several candidates that asks the reviewer question now (a reviewer named with the request, like "autonomously, mb reviews", already answers it). Carry the answer to Step 8.

---

## Step 2: Load Sprint Context

- Check `docs/` for planning docs and sprint notes
- Read for relevant context: decisions already made, patterns established, related work in progress

---

## Step 3: Plan

Enter plan mode. Read the codebase — relevant files, existing patterns, architecture.

**Architectural risk scan:** Evaluate against [references/engineering-conventions.md](../../references/engineering-conventions.md) (loaded in Prerequisites). Surface findings only when risks are present — skip if nothing is flagged:

```
⚠ Risk: {name}
Why it matters: {brief explanation}
Better path: {recommendation}
Ask: {1–2 followup questions}
```

Produce implementation plan following [templates/implementation-plan.md](../../templates/implementation-plan.md).

Refine complexity — if the plan reveals scope differs from the ticket's `complexity` score, note the updated value for the Greenhouse update in Step 5.

If complexity reaches 64, warn the user: *"This is scoring 64pt — it's a large ticket. Want to split it, or proceed as one PR?"* If they choose to proceed, continue normally with self-review checkpoints between phases.

### Interactive mode (default)
Present plan, iterate until approved. Wait for explicit approval before coding.

**Declare the phase boundaries in the plan.** Name each phase, its one-line scope, and what will be verifiable at its boundary — including phases with nothing observable. The user is approving *where the breaks fall* as much as the work itself, and boundaries revealed one at a time give them no chance to move them. See [references/checkpoint-handoff.md](../../references/checkpoint-handoff.md#declaring-phases-up-front).

### Autonomous mode
Post plan to Greenhouse (Step 5 comment), proceed directly to implementation.

---

## Step 4: Branch

### Determine Branch Name
Pattern: `{initials}/{ticket-id-lowercase}-{short-description}`

`{initials}` is your lowercased `initials` from `org_avatar_directory` — the one-call lookup in [conventions §Current user resolution](../conventions/SKILL.md#current-user-resolution). Never the Team table (it has no initials column) and never a legacy CLAUDE.md `Initials` value. If the lookup fails, use the first two letters of `${GREENHOUSE_TEAM_USERNAME}` and say so.

Resolve `{base}` with [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch).

### Where the Work Happens

Before branching, check whether the cwd is a worktree ([common-operations §Worktrees](../../references/common-operations.md#worktrees)). If it is, read its branch: when that branch belongs to a **different** ticket, or to a ticket that is `harvest` or `weeded`, stop — don't start new work in a finished ticket's worktree:

> "This is the worktree for {other-ticket} ({status}). Remove it and continue {TICKET-ID} from the main checkout at {path}?"

Then state where the work will happen: *"Working in {the current checkout | a new worktree at {path}}."*

- **Interactive:** use the current checkout. Propose a worktree only when you judge one warranted (e.g. the main checkout has another ticket's uncommitted work), and always ask before creating it.
- **Autonomous:** use the current checkout. Never create a worktree.

### Resuming Existing Branch
If a branch matching the ticket ID already exists:
1. Checkout the branch
2. If behind `{base}` — [Inline Rebase](../../references/common-operations.md#inline-rebase)
3. Run a quick quality check: lint + typecheck
4. Fix any issues from rebase
5. Inform user: *"Resumed branch {branch}. It's {N} commits ahead of {base}."*

### Fresh Start

```bash
git fetch origin {base}
git checkout -b {branch-name} origin/{base}
```

When `{base}` is an epic branch, note in the implementation plan: "Stacked on epic branch {epic_branch}."

### Stacked Branch (off another feature branch)
If the ticket has a dependency on an unmerged PR:
1. Interactive: confirm with user — *"RG-7 depends on RG-4 which is in PR #{N} on branch `{branch}`. Branch off that instead?"*
2. Autonomous: branch off parent automatically, note in implementation plan
3. Note in implementation plan that this is a stacked branch

---

## Step 5: Update Greenhouse

Single `PATCH /rest/v1/tickets?display_id=eq.{ID}` (batch all fields in one call):
- `status` → `in_bloom`, `started_at` → current instant as a full ISO-8601 timestamp — `date -u +%Y-%m-%dT%H:%M:%SZ`. **Never a bare date:** Postgres coerces `2026-09-12` to midnight UTC, which is the previous evening in any western timezone, so cycle time is skewed at the start exactly as GH-75 found it skewed at the end (190 of 326 harvested tickets carry a coerced `started_at`)
- `branch_name` → the Step 4 branch; `assignee` → `${GREENHOUSE_TEAM_USERNAME}` (if not set)
- `implementation_plan` → approved plan
- `complexity`, `open_decisions` → if refined in Step 3
- `updated_by` → `${GREENHOUSE_TEAM_USERNAME}` (interactive) or `"claude"` (autonomous)

`POST /rest/v1/comments` with `{"ticket_id": "{uuid}", "org_id": "${GREENHOUSE_ORG_ID}", "author": "${GREENHOUSE_TEAM_USERNAME}", "body": "..."}` (`"claude"` in autonomous mode, matching `updated_by`) noting branch and mode (interactive or autonomous).

### 5.1 Start Session Timer

Start or resume the session timer using the Session Timer pattern from [references/common-operations.md](../../references/common-operations.md). Lookup is scoped by `ticket_id` so parallel timers for other tickets are never disturbed. The new entry sets `project_id` from the ticket's project so per-project breakdowns and recent-projects quick-pick (in `/time`) include skill-started work.

Then write a ticket marker so the next `/greenhouse:sync-usage` run can tag the Claude usage rows with this ticket:

```bash
mkdir -p "${HOME}/.claude/projects/$(pwd | sed 's:/:-:g')" && \
printf '%s\n' "{ticket_uuid}" > "${HOME}/.claude/projects/$(pwd | sed 's:/:-:g')/.greenhouse-ticket"
```

The encoded folder name matches Claude Code's session-log convention (slashes → dashes). `sync-usage` reads this marker and sets `claude_usage_projects.ticket_id` on the next upsert. The marker is overwritten when another ticket is started in the same directory (only one active ticket per project dir at a time).

Stopping is not handled here — the idle-shutoff sweep closes any timer whose `last_heartbeat_at` is older than 1 hour and backdates `end_time` to the last heartbeat (so idle time isn't credited). The marker file stays until overwritten by the next ticket; this is acceptable because Claude sessions immediately after the timer closes are almost always still on the same ticket.

---

## Step 6: Implement

Follow RIVERROOT conventions from [references/riverroot.md](../../references/riverroot.md) and [references/engineering-conventions.md](../../references/engineering-conventions.md) (complexity signals, direction drift, AI over-generation patterns).

### Interactive mode

Work with the user. Post implementation notes to Greenhouse at key decision points. Follow scope creep rules from [references/work-breakdown.md](../../references/work-breakdown.md).

**Emit a checkpoint handoff at every phase or milestone boundary** using [references/checkpoint-handoff.md](../../references/checkpoint-handoff.md) — at every boundary, regardless of ticket complexity. The user chose interactive over autonomous, which means the breaks are what they asked for: each one states what now works that didn't before, what they should be aware of (assumptions, deferred items, anything you changed about their environment or working tree), a concrete place to go look at it, and a one-word-answerable ask. Then **wait** — the pause is the point.

A handoff whose next-step ask goes unanswered is not permission to continue.

**Gate — Scope Discovery:** On discovering work outside the current acceptance criteria, apply the user-story test: does this serve the same user story as the ticket?

> "Found additional work: {description}.
> **Same user story** (a user would describe this and the ticket's goal in one sentence) → do it now.
> **Different user story** (serves a different user need or workflow) → add it to the out-of-scope findings list."

Never create a follow-up ticket from here — findings follow [common-operations §Out-of-Scope Findings](../../references/common-operations.md#out-of-scope-findings), and a ticket is filed only when the user says yes to a specific item.

When all acceptance criteria are met, proceed to Step 7 (Self-Review) before opening the PR.

### Autonomous mode

Write code. Write tests. Run the quality gate (see conventions). Fix failures; retry up to 3 times on the same error.

**Quality gate failure after 3 attempts:**
1. Revert ticket state — clear `implementation_plan`, `branch_name`, `started_at` via PATCH
2. Post failure comment with details
3. Stop

**Gate — Scope Discovery (autonomous):** If scope expands, add the finding to the out-of-scope list ([common-operations §Out-of-Scope Findings](../../references/common-operations.md#out-of-scope-findings)) and continue with the original scope only. Make no `create_ticket` call — the list is shown at the end of the run (Step 8) and a ticket is filed only on a yes.

When implementation is complete, proceed to Step 7 (Self-Review).

---

## Step 7: Self-Review

Applies to **both** interactive and autonomous modes. Load [references/pre-pr-checklist.md](../../references/pre-pr-checklist.md), [references/review-patterns.md](../../references/review-patterns.md), and the repo's own `.claude/review-patterns.md` when it exists.

### 7.1 Review Changes

`{base}` from [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch):

```bash
git diff {base}...HEAD --stat
git diff {base}...HEAD
```

### 7.2 Run Pre-PR Checklist

Evaluate the diff against every section of [references/pre-pr-checklist.md](../../references/pre-pr-checklist.md):

1. **Acceptance Criteria Mapping** — For each criterion from the ticket, produce a mapping table:

| Criterion | Status | Evidence |
|-----------|--------|----------|
| {criterion text} | Met | {file:line or test name} |
| {criterion text} | Not Met | {what's missing} |

If Given/When/Then behavior specs exist, verify a test exercises each scenario. If any criterion is Not Met and is a blocker, do not proceed to Step 8.

2. **RIVERROOT Standards** — Check each item in the checklist
3. **Security Surface** — Scan for secrets, PII, missing auth checks
4. **AI Over-Generation** — For each pattern found, ask: "Is this the simplest solution?" If simpler code works, simplify before proceeding
5. **Simplicity** — Flag complexity signals; justify or refactor
6. **Direction Drift** — Verify new code follows established patterns
7. **Commit Discipline** — No debug artifacts, no commented-out code

### 7.3 Check Review Patterns

Scan the diff for known patterns from [references/review-patterns.md](../../references/review-patterns.md) and `.claude/review-patterns.md`. Flag any matches.

### 7.4 Fix & Present

**Interactive mode:** Present self-review findings to the user:

```
## Self-Review: {ticket-id}

### Acceptance Criteria
{mapping table}

### Checklist Results
{pass/concern/fail per section}

### Issues Found
{list of issues, if any}

All clear — ready to open PR, or address issues first?
```

Wait for user confirmation before proceeding to Step 8.

**Autonomous mode:** Fix all issues found automatically, re-run quality gate. If a criterion can't be met and it's a blocker, revert status to `sprouted`, comment why, stop.

---

## Step 8: Open PR

Invoke `/greenhouse:open-pr` to commit, push, create the PR, and update Greenhouse. Hand it, so its single ticket PATCH carries everything and nothing is re-fetched:
- the ticket context you already hold (open-pr's ticket gate reuses it instead of calling `get_ticket_context` again)
- `acceptance_criteria` with every criterion the Step 7.2 mapping found **Met** ticked (`- [ ]` → `- [x]`) — criteria are ticked here, once, never one PATCH per criterion
- **Autonomous only:** the reviewer settled in Step 1.4 so open-pr asks nothing, plus `ai_implemented` → `true`, `implementation_notes` → summary of what was built, decisions made, deviations from plan, and `updated_by` → `"claude"`. These ride in open-pr's PATCH — never a second PATCH after it.

Post summary comment: `"Implementation complete. PR #{number} opened. Ready for review by {reviewer}."` — or `"… No reviewer requested."` when there is none. Append the out-of-scope findings list when it isn't empty, and show the same list in the final message.

---

## Status Updates

| Event | Greenhouse Action |
|-------|------------------|
| Work begins | PATCH: `status` → `in_bloom`, `started_at` set to a full ISO-8601 instant (never a bare date) |
| Decision made | POST comment with rationale |
| Acceptance criterion met | Nothing yet — all met criteria are ticked in open-pr's single PATCH (Step 8) |
| Scope change | POST comment explaining decision |
| Work paused (interactive) | Emit a [checkpoint handoff](../../references/checkpoint-handoff.md) AND post comment noting where we left off |
| Ready for PR | Hand off to `/greenhouse:open-pr` |

---

## Error Handling

| Error | Action |
|-------|--------|
| Quality gate fails 3+ attempts (autonomous) | Revert ticket to `sprouted`, clear plan/branch/started_at, comment with failure details, stop |
| Branch already exists | Check for uncommitted work — offer to continue or fresh start |
| Greenhouse API unreachable | Fall back to git-only workflow; queue Greenhouse updates |
| Blocker not resolved | Note in relations, offer to implement blocker first or proceed anyway |
| Acceptance criteria unclear | Comment on ticket asking for clarification; offer a spike ticket, created (with its blocker relation) only on a yes |

---
description: Create Greenhouse tickets for new work — from a single ticket to a full epic breakdown. Also handles replanning an epic when requirements or learnings change. Use when creating a ticket, adding a ticket, planning work, planning features, breaking down work, replanning, updating a plan, or any time new work needs tracking.
argument-hint: "[feature description]"
---

# Skill: Create Ticket

The canonical path for creating any new ticket. Handles single tickets, multi-ticket breakdowns, and full epic planning.

---

> **Before you respond:** Consider what the developer actually needs, not just what was asked. Give the best answer for their underlying goal, then surface 2–3 followup questions they should ask to go deeper.

---

## Prerequisites

- Check `docs/` for sprint planning docs — what's already planned, in progress, or done
- Load [references/work-breakdown.md](../../references/work-breakdown.md) for sizing heuristics

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

Then identify the project or handle replan:

### Replan mode

If the user asks to replan an epic (e.g. "replan the auth epic", "update the plan for GH-5"):

1. Skip Steps 1-3; jump directly to gathering current state
2. Fetch ticket overview for the epic:
   ```
   GET /rest/v1/tickets?epic_id=eq.{epic_uuid}&select=display_id,title,status,priority,type,complexity,assignee,started_at,completed_at,branch_name,pr_url&order=priority.asc
   GET /rest/v1/epic_progress?epic_id=eq.{epic_uuid}
   ```
3. Drill into tickets that need modification using `get_ticket_context`; check git log for recent merges; read `docs/` for context
4. Identify: tickets no longer needed, new tickets needed, priority/order changes, outdated criteria, tickets to split or combine
5. Present proposed changes (cancel / modify / keep / new tickets) and iterate until approved
6. Execute: cancel tickets in ONE `PATCH /rest/v1/tickets?display_id=in.({A},{B},{C})` → `{"status": "weeded", "updated_by": "${GREENHOUSE_TEAM_USERNAME}"}` (never one PATCH per ticket), modify tickets (PATCH fields — one PATCH per ticket, all its fields together), create new tickets (use Step 6 RPC below)
7. Update `docs/` planning docs if present
8. Output updated implementation order table with recommended next ticket

If no `--replan` flag, proceed with normal project identification below.

### Normal mode

Determine the target project:

1. Check current git repo → read `project_id` from the `greenhouse` config block in CLAUDE.md
2. If ambiguous or no repo context → ask which project
3. Load project config (repo, tech stack, default branch)

---

## Step 1: Understand the Scope

Detect the input type and handle accordingly:

| Input type | How to detect | Action |
|---|---|---|
| **File path(s)** | Argument looks like a path or `@file` | Read each file; detect type from extension/content |
| **Transcript** | Conversational tone, speaker turns, meeting notes | Extract intent, decisions, and open items |
| **PRD / tech spec** | Structured doc with sections (Overview, Requirements, etc.) | Extract requirements as acceptance criteria candidates |
| **Data schema** | SQL DDL, JSON Schema, type definitions | Extract relevant tables/fields; use for acceptance criteria and ticket descriptions |
| **Ticket display ID** | Matches ticket ID pattern | `POST /rest/v1/rpc/get_ticket_context` with `{"p_display_id": "{ID}"}` |
| **Plain description** | None of the above | Analyze scope as today |

After reading inputs:
- Note which files were used as source material. Without an epic (the normal case) they go in a **Source** section of each ticket's description, one line per doc (`PRD: {path or URL}`, `Schema: {path}`, `Transcript: {path}`, `Spec: {URL}`). With an epic the user asked for, they become `planning_refs` on the epic instead (key: `prd` for PRD/spec, `schema` for DDL/schema files, `transcript` for meeting notes/transcripts, `spec_url` for web URLs)

**Default to ONE ticket.** A single ticket is the normal outcome — prepare one ticket with all fields, present for approval, create it. Skip Step 3 (decomposition) and the epic logic entirely.

**Only decompose when** the user explicitly asks for a breakdown/epic, OR a hard dependency forces separate PRs (e.g. a migration must merge before the code that depends on it can even build). Scope alone is not a reason — AI handles large vertical slices well, and one big reviewable PR beats several coordinated ones. When unsure, make it one ticket and say so. If you do decompose, continue to Step 3.

---

## Step 2: Check for Existing Tickets

Query the Tickets table for the target project — look at all non-harvest, non-weeded tickets:

```
GET /rest/v1/tickets?project_id=eq.{id}&status=not.in.(harvest,weeded)&select=display_id,title,status,priority,type,assignee
```

Scan for overlap with the proposed work:
- Duplicate tickets that already cover this work
- Tickets that need updating based on the new plan
- Tickets that should be cancelled as obsolete

If overlaps found:
> "These existing tickets overlap: {list}. I'll propose edits for overlapping tickets and only create new ones for gaps."

---

## Step 3: Break Down the Work

Apply the vertical slice rule and sizing heuristics from [references/work-breakdown.md](../../references/work-breakdown.md).

For each proposed ticket, prepare:

| Field | Value |
|-------|-------|
| **Title** | One sentence, imperative voice |
| **Type** | `feature`, `bug`, `chore`, `spike`, `infrastructure`, `tech_debt`, `hotfix`, `no_code` (design/copy/research/decision work that never has a PR — harvests from the web UI) |
| **Priority** | `p0_critical`, `p1_high`, `p2_medium`, `p3_low` — inferred, user can override |
| **Acceptance Criteria** | Checkbox list of specific, testable outcomes |
| **Labels** | 2-5 labels per ticket, inferred from what the work touches (see conventions skill Labeling Philosophy) |
| **Compliance Tags** | `soc2`, `iec_62304`, `hipaa`, `pii` if applicable |
| **Blocked By** | Tickets that must complete before this one can proceed |
| **Complexity** | `1`, `2`, `4`, `8`, `16`, `32`, `64` — rough score from description (Confidence: low, refined later by `tend-ticket`) |
| **Assignee** | Per assignment rules below — may be unassigned |
| **Reviewer** | [conventions §Reviewer Rule](../conventions/SKILL.md#reviewer-rule) with the assignee as implementer — pre-filled when the rule yields one candidate, blank when it would ask unless the user names one |

When source documents were provided in Step 1, track them here — they go in each ticket's Source section (Step 6), or on the epic's `planning_refs` if the user asked for an epic (Step 5).

### Sizing Checks (apply to every ticket)

- Can it be described in one sentence?
- Does completing it leave the codebase in a working state?
- Is it a vertical slice, not a horizontal layer?
- Would the final PR be reviewable as a single cohesive change? (Size is fine — reviewability is the constraint.)

### Assignment Rules

1. **Assignee** — a solo team (one Team-table row) assigns its one member, no question. Otherwise ask once who should own which tickets; "no preference" leaves them **unassigned** — `work-ticket` sets the assignee when someone picks the ticket up. Assignee values are Team-table **Greenhouse** usernames (`${GREENHOUSE_TEAM_USERNAME}` for yourself), never a name, initials or GitHub login
2. **Reviewer** — shown per ticket in the Step 4 table, never a separate question. [conventions §Reviewer Rule](../conventions/SKILL.md#reviewer-rule) with each ticket's assignee as the implementer: pre-filled when the rule yields exactly one candidate, blank when it would ask — `open-pr` asks when the PR opens unless the user names one
3. The user can change either in their Step 4 feedback; "unassigned" and "no reviewer" are valid answers

---

## Step 4: Present for Review

Show the full breakdown with implementation order BEFORE creating anything:

```
## Proposed Tickets for {feature}

### Implementation Order

1. **{Title}** [{type}] [{N}pt {approach}] → {assignee | unassigned} · reviewer: {reviewer | —}
   Labels: `auth`, `api`, `database`
   - {Acceptance criterion 1}
   - {Acceptance criterion 2}
   Blocked by: (none)

2. **{Title}** [{type}] [{N}pt {approach}] → {assignee | unassigned} · reviewer: {reviewer | —}
   Labels: `frontend`, `auth`, `ux`
   - {Acceptance criterion 1}
   Blocked by: #1

...
```

Before asking for approval, present a combine check if breakdown has 2+ tickets:
> "This breakdown has {N} tickets. Every ticket becomes a PR that a human must review — review coordination cost grows with each additional PR. AI handles large vertical slices well, so fewer bigger tickets is almost always better. Could any of these be combined? (More than 3 tickets for one feature is usually over-decomposing.)"

Iterate until the user approves. Accept feedback to:
- Combine tickets
- Split tickets further
- Reorder
- Relabel or reassign
- Adjust acceptance criteria
- Change complexity scores

---

## Step 5: Epic (only when asked)

**Skip this step unless the user asked for an epic in this conversation** ("put these under an epic", "link to the auth epic"). However many tickets the breakdown has, the default is no epic, and the skill never suggests one. See [conventions §Epic Usage](../conventions/SKILL.md#epic-usage).

### Link to an Existing Epic
When the user named an existing epic:
- `GET /rest/v1/epics?project_id=eq.{id}&status=not.eq.weeded&select=id,name,status,priority,labels` — find the one they named
- Link the tickets to it
- If the epic has no `planning_refs` and source docs were provided in Step 1, offer to `PATCH /rest/v1/epics?id=eq.{epic-id}` to add them

### Create New Epic
When the user asked for a new epic:
- `POST /rest/v1/epics` with `Prefer: return=representation`:
  - `project_id`: target project UUID
  - `name`: feature name
  - `status`: `planning`
  - `priority`: highest priority among tickets
  - `owner`: `${GREENHOUSE_TEAM_USERNAME}`
  - `labels`: aggregate of ticket labels (the superset)
  - `acceptance_criteria`: overall "done" definition for the feature
  - `created_by`: `${GREENHOUSE_TEAM_USERNAME}`
  - `updated_by`: `${GREENHOUSE_TEAM_USERNAME}`
  - `org_id`: `${GREENHOUSE_ORG_ID}` — required by RLS on a raw table insert (unlike the `create_ticket` RPC, which infers it from the project)
  - `planning_refs`: JSONB object built from source documents identified in Step 1 — only include keys that are present:
    ```json
    {
      "prd": "<path or URL if a PRD/tech-spec was provided>",
      "schema": "<path if a schema file was used>",
      "transcript": "<path if a transcript/meeting notes were used>",
      "spec_url": "<URL if a web spec was referenced>"
    }
    ```
    Omit `planning_refs` entirely if no source documents were provided.

If the breakdown has 8+ tickets, warn about scope:
> "This is a large epic ({N} tickets). Consider phasing the work."

### Epic Branch

If the epic has 2+ tickets, create an epic branch immediately after the epic record is created, cut from the integration branch (rungs 4–5 of [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch)):

```bash
git fetch origin {integration-branch}
git checkout -b epic/{epic-display-id}-{slug} origin/{integration-branch}
git push -u origin epic/{epic-display-id}-{slug}
```

Where `{slug}` is the epic name lowercased and hyphenated (e.g. `epic/gh-5-plugin-audit`).

Then PATCH the epic to record the branch:
```
PATCH /rest/v1/epics?id=eq.{uuid}
{"epic_branch": "epic/{epic-display-id}-{slug}", "updated_by": "${GREENHOUSE_TEAM_USERNAME}"}
```

Inform the user: *"Created epic branch `epic/{epic-display-id}-{slug}`. All ticket branches will stem from it."*

---

## Step 6: Create Tickets

For each approved ticket, create via `POST /rest/v1/rpc/create_ticket`:

- `p_project_id`: project UUID
- `p_title`: ticket title
- `p_type`, `p_priority`, `p_complexity` (rough score — Confidence: low)
- `p_assignee`, `p_reviewer` (Team-table Greenhouse values, e.g., `"dan"`, `"mb"`) — omit either when it's unassigned / no reviewer
- `p_labels` (array, e.g., `["frontend", "auth", "api"]`)
- `p_compliance_tags` (array, if applicable)
- `p_acceptance_criteria` (rich text — checkbox list)
- `p_summary` (one/two-sentence, non-technical "what this delivers for a user" — becomes the Slack notification body for this ticket's lifecycle events; always set it)
- `p_epic_id` (UUID) — omit unless planning established an epic (Step 5)
- `p_description` (ticket body following [templates/ticket-body.md](../../templates/ticket-body.md)); with no epic and source docs from Step 1, include the **Source** section
- `p_created_by`: `${GREENHOUSE_TEAM_USERNAME}`

`p_acceptance_criteria` and `p_description` are multi-line markdown — construct the RPC payload using the temp-file + `--rawfile` pattern in [references/common-operations.md](../../references/common-operations.md) §Posting Comments and PATCHing Multi-line Ticket Fields. Do NOT use `jq -n --arg p_description "..."` with a literal multi-line string.

Capture `display_id` from the response for each ticket.

### Wiring Blocked-By Relations
For tickets with blockers referencing other tickets in this batch or existing tickets:
1. `POST /rest/v1/rpc/resolve_display_ids` with `{"p_display_ids": ["{ID1}", "{ID2}"]}` to get UUIDs
2. `POST /rest/v1/ticket_relations` for each relation: `{"source_ticket_id": "{blocker-uuid}", "target_ticket_id": "{blocked-uuid}", "relation_type": "blocks", "created_by": "${GREENHOUSE_TEAM_USERNAME}", "org_id": "${GREENHOUSE_ORG_ID}"}` — `org_id` is required by RLS; use `${GREENHOUSE_ORG_ID}` from the `gh-jwt` eval (see [common-operations §org_id on writes](../../references/common-operations.md#org_id-on-writes)).

---

## Step 7: Update Existing Tickets (if replanning)

If Step 2 found overlapping tickets:

- Tickets being cancelled: ONE `PATCH /rest/v1/tickets?display_id=in.({A},{B},{C})` with `{"status": "weeded", "updated_by": "${GREENHOUSE_TEAM_USERNAME}"}` — not one per ticket
- Other tickets needing changes: `PATCH /rest/v1/tickets?display_id=eq.{ID}`, all of that ticket's fields in one call, with `updated_by`: `${GREENHOUSE_TEAM_USERNAME}`
- `POST /rest/v1/comments` on updated tickets explaining what changed and why (`author`: `${GREENHOUSE_TEAM_USERNAME}`; include `org_id` from `${GREENHOUSE_ORG_ID}`)

---

## Step 8: Update Planning Docs

If `docs/` has sprint planning docs:
- Update with new ticket IDs and their place in the sequence
- Note any tickets that were cancelled or modified

---

## Step 9: Output Summary

Present a final summary table:

```
| # | Ticket ID | Title | Type | Complexity | Assignee | Reviewer | Blocked By |
|---|-----------|-------|------|------------|----------|----------|------------|
| 1 | {ID}      | ...   | ...  | 4pt plan   | dk       | mc       | —          |
| 2 | {ID}      | ...   | ...  | 2pt direct | —        | —        | #1         |
```

Identify the recommended starting ticket (first unblocked, or highest priority if none are blocked).

---

## Step 10: Hand Off

Ask:
> "Want to start on a ticket now?"

If yes:
- Ticket needs tending → offer to tend it first: *"Want me to tend {ticket-id} before we start? That sets up better acceptance criteria and file targets."*
- Ticket is tended (or user wants to proceed) → offer to start: *"Ready to start on {ticket-id}?"* and invoke the work-ticket skill

Do NOT start implementation manually — always route through the work-ticket skill.

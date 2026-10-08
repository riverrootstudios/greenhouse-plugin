---
description: Cross-project status overview. Shows in-flight work, blocked items, PRs awaiting review. Use when asking about status, what is in flight, or checking the board.
---

# Skill: Dashboard

Cross-project status overview. Shows all in-flight work, blocked items, PRs awaiting review, and compliance gaps.

---

> **Before you respond:** Consider what the developer actually needs, not just what was asked. Give the best answer for their underlying goal, then surface 2–3 followup questions they should ask to go deeper.

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

Verify `GREENHOUSE_URL`, `GREENHOUSE_PUBLIC_KEY`, and `GREENHOUSE_API_KEY` are set. If missing, output setup instructions and stop.

---

## Step 1: Query Data

**Scope:** default to the one project in this repo's CLAUDE.md `greenhouse` fence (`project_id`). Go org-wide only when the user asks ("all projects", "everything", `--all`) or there is no fence — then drop the `project_id=eq.{id}` filters below (RLS already scopes to your org) and add the projects query. Never loop the queries per project.

Run all of the following Greenhouse curl calls and the `gh pr list` call as **parallel tool calls in a single message** — do not run them sequentially:

### Greenhouse

```bash
# Active projects (org-wide mode only)
curl -s "${GREENHOUSE_URL}/rest/v1/projects?archived_at=is.null&select=id,name,key" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"

# Project summary (ticket counts by status)
curl -s "${GREENHOUSE_URL}/rest/v1/project_summary?project_id=eq.{id}&select=project_id,name,key,seeds_count,sprouted_count,in_bloom_count,in_review_count,changes_requested_count" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"

# Active tickets — carries the small fields the Step 2 gap checks need (no text bodies)
curl -s "${GREENHOUSE_URL}/rest/v1/tickets?project_id=eq.{id}&status=not.in.(harvest,weeded)&select=display_id,title,status,priority,type,assignee,branch_name,pr_url,epic_id,tended,started_at,updated_at&order=priority.asc&limit=200" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"

# Active tickets with no acceptance criteria — a filter, never the AC text
curl -s "${GREENHOUSE_URL}/rest/v1/tickets?project_id=eq.{id}&status=not.in.(harvest,weeded)&acceptance_criteria=is.null&select=display_id&limit=100" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"

# Blocked tickets
curl -s "${GREENHOUSE_URL}/rest/v1/blocked_tickets?project_id=eq.{id}&select=display_id,title,status,priority,blocked_by&order=priority.asc&limit=50" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"

# Recently completed (last 7 days)
curl -s "${GREENHOUSE_URL}/rest/v1/tickets?project_id=eq.{id}&status=eq.harvest&completed_at=gte.{7-days-ago-ISO}&select=display_id,title,completed_at&order=completed_at.desc&limit=50" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"

# Epics (detailed mode only)
curl -s "${GREENHOUSE_URL}/rest/v1/epics?project_id=eq.{id}&status=not.eq.weeded&select=id,name,status,priority,labels&limit=50" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"
```

### GitHub PRs

```bash
gh pr list --json number,title,author,createdAt,reviewDecision,statusCheckRollup --state open
```

If `gh` fails, skip PR data and note it in the output.

---

## Step 2: Detect Gaps

All of these come from the Step 1 rows — no further Greenhouse reads.

### Compliance Gaps
- Tickets without acceptance criteria (the `acceptance_criteria=is.null` query)
- PRs without linked Greenhouse tickets
- Tickets in `in_review` without a PR (`pr_url` null)
- `in_bloom` tickets with no branch (`branch_name` null)

### SLA Gaps
- PRs open > 4 hours without review
- Tickets in `in_bloom` for > 3 days (`started_at`)
- Tickets in `changes_requested` for > 1 day (`updated_at` — the last write, usually the review verdict)

### Process Gaps
- Orphaned branches (branch exists, no ticket)
- Stale `in_bloom` tickets (no commits in 2+ days)
- Untended tickets in `sprouted` status (`tended` false)

---

## Step 3: Present Dashboard

Render a clear, scannable overview. Use the Greenhouse status symbols:

| Status | Symbol |
|--------|--------|
| `seeds` | 🌱 |
| `sprouted` | 🌿 |
| `in_bloom` | 🌸 |
| `in_review` | 🔍 |
| `changes_requested` | ⚡ |
| `harvest` | 🌾 |
| blocked | 🚫 |

### What to show

1. **Kanban board** — tickets grouped by status, showing ticket ID, title, priority, assignee
2. **Blocker graph** — blocked tickets with their blockers (only when blockers exist)
3. **Epic progress** — per-epic ticket breakdown with progress (detailed mode only)
4. **Team load** — ticket count per assignee by status
5. **PR pipeline** — open PRs with review status, CI status, SLA check (4h threshold)
6. **Harvest feed** — recently completed tickets (last 7 days)
7. **Gaps & warnings** — all detected gaps from Step 2

Use good visual formatting (tables, box-drawing, progress bars) but don't over-specify — adapt the layout to the data.

### Output Modes

- **Brief (default):** Kanban + blockers + PR pipeline + harvest + gaps
- **Detailed:** All components including epic tree
- **Board:** Kanban only + gaps
- **Graph:** Blocker graph only

### Filters

Support filtering by project, assignee (`--assignee`), label (`--label`), or compliance tag (`--compliance`).

---

## Step 4: Suggest Next Actions

Based on the dashboard state, suggest actionable next steps:

- PRs awaiting review → *"PR #{number} is awaiting review — want to review it?"*
- Changes requested → *"There's review feedback on {ticket-id} — want to address it?"*
- Sprouted tickets ready → *"Ready to start {ticket-id}: {title}?"*
- Gaps detected → *"There are sync inconsistencies — want me to run a health check?"*
- Untended seeds → *"Several tickets need tending — want to tend {ticket-id} next?"*

---

## Error Handling

| Error | Action |
|-------|--------|
| Greenhouse API unreachable | Show whatever data is available from GitHub; note Greenhouse is down |
| `gh` CLI fails | Skip PR data; note GitHub data unavailable |
| No active projects | Report "No active projects found" |
| Empty board | Report "All clear — no active tickets" |

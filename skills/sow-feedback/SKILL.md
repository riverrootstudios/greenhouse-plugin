---
description: Digest a brainstorm note into created or updated tickets — sow raw design-partner feedback (Slack threads, Google Docs, transcripts) into the backlog. Use when sowing feedback, triaging a brainstorm, processing a feedback dump, or turning notes into tickets.
argument-hint: "[note-id or search text]"
---

# Skill: Sow Feedback

Turn a raw brainstorm note into tracked work through an explicit triage loop. A note is **Raw** until it has been sown at least once, then **Planted**. Every candidate requirement gets an explicit decision — nothing is silently dropped.

**Slack boundary:** this skill never calls Slack and never formats a message. Created tickets notify via the `created` event; updates notify by writing `change_note` and enqueuing the `updated` event through `log_ticket_change`. Delivery is entirely Greenhouse's cron (see [Lifecycle Notifications](../../references/common-operations.md#lifecycle-notifications)).

---

## Step 0: Preflight

Run Sync Queue Replay from [references/common-operations.md](../../references/common-operations.md) (check for `.claude/greenhouse-sync-queue.json`).

**Session Authentication** — run this before ANY Greenhouse API call:

```bash
eval "$(${CLAUDE_PLUGIN_ROOT}/bin/gh-jwt)"
```

**Step 0 Heartbeat:**

```bash
${CLAUDE_PLUGIN_ROOT}/bin/gh-heartbeat
```

Resolve the project from the `greenhouse` config block in CLAUDE.md.

---

## Step 1: Pick a Note

If an argument was given, resolve it as a note id or a body search term (`&body=ilike.*{term}*` as a filter — still not in `select`). Otherwise list the project's 20 newest notes, Raw first. **Never select `body` in the list** — bodies are whole Slack threads and transcripts:

```
GET /rest/v1/brainstorm_notes?project_id=eq.{project_id}&archived=eq.false&select=id,project_id,title,summary,author,tags,dept,source_attribution,created_at,brainstorm_triage(triaged_by,triaged_at,tickets_touched)&order=created_at.desc&limit=20
```

Present — the note's `title` when it has one, otherwise the first ~60 characters of its `summary`, otherwise `(untitled, {relative date})` (GH-67):

```
Raw (never sown):
  [1] "{title, or first ~60 chars of summary}" — {author}, {relative date}, tags: {tags}{, dept: {dept}}{ — feedback from {source_attribution}}
Planted:
  [2] "{...}" — sown by {triaged_by list} → {display_ids}
```

A Planted note can be sown again (a second pass tallies a new triage row). Confirm the selection.

---

## Step 2: Digest

Fetch the chosen note's body — alone, once:

```
GET /rest/v1/brainstorm_notes?id=eq.{note_uuid}&select=body,source_url
```

Break the raw dump into a **numbered list of atomic candidate requirements** — one behavior/need per item, deduplicated across sources (a Slack thread and a call transcript often repeat the same ask; note the repetition, it signals priority).

Show the list to the user before triaging. This list is the coverage guarantee: every item below gets an explicit decision.

---

## Step 3: Triage Each Requirement

Fetch the project's open tickets **once per run**, before the first candidate, and reuse that list for every requirement:

```
GET /rest/v1/tickets?project_id=eq.{id}&status=not.in.(harvest,weeded)&select=display_id,title,status,type,assignee,summary
```

For each candidate, run the four checks in order:

1. **Exists check** — match the candidate against the open-ticket list above (no new query per candidate). For any matched ticket, pull its context — including comments — with `POST /rest/v1/rpc/get_ticket_context`. Comments are notes, not a workflow state: read them as context so the triage decision accounts for what's already been discussed.
2. **Accept or modify** — present the requirement as extracted; the user accepts it as-is or refines wording/scope.
3. **Simplicity check** — challenge the scope: what's the smallest version that's still useful? Propose the minimal implementation; flag anything that smells like a bigger lift than the feedback justifies.
4. **Decision** — one of:
   - **Create** a new ticket — code work that ends in a PR
   - **Create (no_code)** — a design, copy, research, or decision follow-up with no PR, using the existing `no_code` type. Never ask for or invent a complexity score for these
   - **Update** an existing ticket (append acceptance criteria)
   - **Drop**, with a reason (recorded, revisitable)

---

## Step 4: Confirm the Batch

Present the full plan before writing anything:

```
About to:
  • CREATE  — "{title}" [{type}]
  • CREATE  — "{title}" [no_code]
  • UPDATE {display_id} — add AC: {one-liner}
  • DROP   R{n} — {requirement} ({reason})
Proceed?
```

Wait for approval. Iterate on feedback.

---

## Step 5: Execute

**Creates** — `POST /rest/v1/rpc/create_ticket` following the field conventions in [skills/create-ticket](../create-ticket/SKILL.md) Step 6. Always include **`p_summary`** (one/two-sentence, non-technical "what this delivers") — it is the Slack message body for this ticket's lifecycle events. For a **no_code** row, send `p_type: "no_code"` and omit `p_complexity` entirely.

When the note carries `source_attribution`, the description **starts** with a source line so the origin of the feedback survives into the ticket (GH-67):

```
**Source:** {source_attribution}

{rest of the description}
```

**Updates** — for each existing ticket:

1. PATCH the ticket: append to `acceptance_criteria` (use the temp-file + `--rawfile` pattern from [common-operations §Posting Comments](../../references/common-operations.md#posting-comments-and-patching-multi-line-ticket-fields)), and set `change_note` to a one-liner: `via brainstorm '{note title/excerpt}': {what changed}`. Include `updated_by`: `${GREENHOUSE_TEAM_USERNAME}`.
2. Enqueue the notification — the note text is frozen at enqueue time by design:
   ```
   POST /rest/v1/rpc/log_ticket_change
   {"p_ticket_id": "{uuid}", "p_actor": "${GREENHOUSE_TEAM_USERNAME}", "p_action": "updated",
    "p_changes": {"notify": true, "change_note": "via brainstorm '{...}': {what changed}"}}
   ```
   The `notify` marker is what makes the row deliverable — a plain PATCH never notifies.

**Note summary** — when the note body is longer than ~600 characters, write a 2–4 sentence digest onto the note's `summary` column (GH-76), which the brainstorm card shows collapsed instead of the body excerpt. Shorter notes are left alone; so is a note whose `summary` someone already wrote.

```
PATCH /rest/v1/brainstorm_notes?id=eq.{note_uuid}
{"summary": "{2–4 sentence digest}"}
```

This goes through PostgREST, not the web app's `/api/brainstorm` route — that route authenticates with a browser session a CLI token doesn't have. Editing a note never re-posts it to Slack (only a note with `notified_at` still null is delivered).

**Traceability** — comment on every touched ticket (created and updated): `Sourced from brainstorm note "{title or excerpt}" during sow-feedback by ${GREENHOUSE_TEAM_USERNAME}, {date}.` When the note has `source_attribution`, name it: `Sourced from brainstorm note "{title or excerpt}" (feedback from {source_attribution}) during sow-feedback by ${GREENHOUSE_TEAM_USERNAME}, {date}.` The comment `author` is `${GREENHOUSE_TEAM_USERNAME}` too. Include `org_id` per [common-operations §org_id on writes](../../references/common-operations.md#org_id-on-writes).

---

## Step 6: Record the Sowing

```
POST /rest/v1/brainstorm_triage
{"note_id": "{note_uuid}", "org_id": "${GREENHOUSE_ORG_ID}", "triaged_by": "${GREENHOUSE_TEAM_USERNAME}",
 "tickets_touched": ["{uuid}", ...],
 "dropped": [{"requirement": "{text}", "reason": "{why}"}, ...],
 "action_summary": "{N} created, {M} updated, {K} dropped"}
```

This flips the note Raw → Planted (the web UI badge reads these rows).

---

## Step 7: Output

```
## Sown: "{note title or excerpt}"

| # | Requirement | Decision | Ticket |
|---|-------------|----------|--------|
| 1 | {req}       | created (code)    | {ID}   |
| 2 | {req}       | created (no_code) | {ID}   |
| 3 | {req}       | updated  | {ID}   |
| 4 | {req}       | dropped — {reason} | — |

{Note summary written — only when the note was long enough to get one.}

Slack lines will deliver via the project's notification rules within ~2 minutes.
{When any no_code ticket was created:} no_code tickets have no PR — they harvest from the web UI (board tile or kanban), never through `/greenhouse:open-pr` or `/greenhouse:merge-pr`.
```

If any created ticket should be worked next, offer to tend it (`/greenhouse:tend-ticket`).

---

## Error Handling

| Error | Action |
|-------|--------|
| No brainstorm notes found | Suggest pasting feedback into the Brainstorm view first |
| Note has no discernible requirements | Say so; offer to archive the note or leave it Raw |
| `create_ticket` / PATCH fails | Queue to `.claude/greenhouse-sync-queue.json` per Greenhouse Fallback; report which writes landed |
| `log_ticket_change` fails after PATCH succeeded | Ticket is updated but won't notify — retry once, then note it in the summary (content is source of truth; the Slack line is best-effort) |
| User rejects the whole batch | Record nothing; the note stays Raw |

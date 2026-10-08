# Status Flows

Valid status transitions for Greenhouse tables. Skills enforce these — invalid transitions are rejected with an explanation.

---

## Ticket Status Flow

```
                      ┌─────────────────────────────────┐
                      │                                   │
seeds → sprouted → in_bloom → in_review → harvest        │
                      ↑               │                   │
                      │         changes_requested ────────┘
                      │               │
                      └───────────────┘
                      (back to in_bloom)

Special:
  weeded — can transition from any state
```

### `no_code` tickets (GH-65)

Work with no PR — design, copy, research, decisions, approvals — goes `sprouted → in_bloom → harvest`, **skipping `in_review`**. There is no `/greenhouse:open-pr` or `/greenhouse:merge-pr` step; the ticket is harvested from the web UI (a board tile's harvest action or a kanban drag). `completed_at` is stamped by the `stamp_ticket_completion` trigger on every path, so Reports still count it.

### Valid Transitions

| From | Allowed To |
|------|-----------|
| seeds | sprouted, weeded |
| sprouted | in_bloom, seeds, weeded |
| in_bloom | in_review, seeds, weeded |
| in_review | harvest, changes_requested, weeded |
| changes_requested | in_bloom, weeded |
| harvest | _(terminal)_ |
| weeded | seeds _(reopen only)_ |

### Transition Triggers by Skill

| Transition | Triggered By |
|------------|-------------|
| seeds → sprouted | `/tend-ticket` (sets tended flag) or manual triage |
| sprouted → in_bloom | `/work-ticket` |
| in_bloom → in_review | `/open-pr` |
| in_review → harvest | `/review-pr` |
| in_review → changes_requested | `/review-pr` (when requesting changes) |
| changes_requested → in_bloom | `/fix-review-feedback` |
| Any → weeded | Manual or `/create-ticket` |
| Blocker detected | Add blocking relation to `ticket_relations` (see below) |

### Blocks / Blocked By (Relations Table)

Greenhouse stores one row in `ticket_relations` with `relation_type = 'blocks'`. The `get_ticket_relations()` RPC resolves both directions: `blocks` and `blocked_by`.

To add a blocker:
```
POST /rest/v1/ticket_relations
{"source_ticket_id": "{blocker_uuid}", "target_ticket_id": "{blocked_uuid}", "relation_type": "blocks", "created_by": "${GREENHOUSE_TEAM_USERNAME}", "org_id": "${GREENHOUSE_ORG_ID}"}
```

`org_id` is required — RLS rejects writes without it. Use `${GREENHOUSE_ORG_ID}` from the `gh-jwt` eval (see [common-operations §org_id on writes](common-operations.md#org_id-on-writes)), not CLAUDE.md — the JWT claim is what RLS evaluates.

To remove a resolved blocker:
```
DELETE /rest/v1/ticket_relations?id=eq.{relation_id}
```

Use `resolve_display_ids` RPC first if you only have display IDs.

This tracks runtime blockers — tickets that prevent work from proceeding. Unlike a status, blocking is orthogonal: a ticket stays in its current stage (seeds, sprouted, in_bloom) while blocked.

| Event | Action |
|-------|--------|
| Blocker found at work-ticket time | `POST /rest/v1/ticket_relations` with `relation_type = 'blocks'` + `org_id` |
| Blocker found during tend-ticket | `POST /rest/v1/ticket_relations` with `relation_type = 'blocks'` + `org_id` |
| Blocker reaches harvest | Remove the relation via `DELETE /rest/v1/ticket_relations?id=eq.{relation_id}` |
| Non-ticket blocker (external decision, unclear spec) | Create a ticket for the blocker, add relation |

Skills check blocker relations before starting work and surface blockers to the user. Dashboard shows blocked tickets as a separate section with their actual status preserved.

---

### Tended Flag

The `tended` boolean is set by `/tend-ticket` and means the ticket has expanded acceptance criteria, scored complexity, and identified files — it's implementation-ready for autonomous coding.

- A ticket can be `sprouted` without being `tended` (manually triaged but not expanded)
- `tended` is permanent — it doesn't reset when a ticket is modified
- `/work-ticket` (autonomous mode) checks `tended` and warns if false (autonomous work benefits most from tending)
- `/work-ticket` (interactive mode) does not require `tended` (the human is in the loop to fill gaps)

---

## Epic Status Flow

```
planning → in_bloom → complete
              ↓
          weeded
```

| From | Allowed To |
|------|-----------|
| planning | in_bloom, weeded |
| in_bloom | complete, weeded |
| complete | _(terminal)_ |
| weeded | planning _(reopen)_ |

### Auto-Transitions

- Epic moves to `in_bloom` when first ticket moves to `in_bloom`
- Epic moves to `complete` when last ticket moves to `harvest`

---

## Project Status Flow

```
active → on_hold → active
active → completed → archived
```

Projects rarely change status via skills — these are managed manually.

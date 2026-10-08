# Greenhouse Schema Reference

Supabase PostgreSQL backend for the Greenhouse plugin. All access via PostgREST REST API.

---

## Enum Types

### ticket_status
`seeds` · `sprouted` · `in_bloom` · `in_review` · `changes_requested` · `harvest` · `weeded`

### ticket_type
`feature` · `bug` · `chore` · `spike` · `hotfix` · `tech_debt` · `infrastructure` · `no_code`

`no_code` (GH-65) is work with no PR — design, copy, research, decisions, approvals. It goes `sprouted → in_bloom → harvest`, skipping `in_review`: no `/greenhouse:open-pr`, no `/greenhouse:merge-pr`; it is harvested from the web UI (board tile or kanban). The `stamp_ticket_completion` trigger sets `completed_at` on that harvest, so it still counts in Reports.

### priority_level
`p0_critical` · `p1_high` · `p2_medium` · `p3_low`

### complexity_score
`1` · `2` · `4` · `8` · `16` · `32` · `64`

### epic_status
`planning` · `in_bloom` · `complete` · `weeded`

### relation_type
`blocks` · `relates_to` · `duplicates` · `caused_by`

### activity_action
`created` · `updated` · `commented` · `relation_added` · `relation_removed` · `status_changed` · `epic_created` · `epic_updated` · `epic_status_changed` · `attachment_added` · `attachment_removed`

`attachment_added` / `attachment_removed` (GH-66) carry `{file_name, size_bytes}` in `value_was`. They are audit-only: `get_deliverable_notifications()` never dispatches them and a Slack rule's `events` CHECK cannot name them.

### pr_stage
`drafting` · `awaiting_review` · `awaiting_changes` · `awaiting_re_review` · `checks_failing` · `ready_to_merge`

Mirrors the `PrStage` TS union exactly (GH-88); the pgTAP suite pins both value sets. Derived by `derivePrStage` in `web/lib/pr-stage.ts`, never hand-set. `checks_failing` replaces `ready_to_merge` when an approved PR is still not mergeable (a red required check, a conflict, or a branch that needs updating).

### pr_checks_state
`none` · `pending` · `passing` · `failing`

GitHub's `mergeable_state` folded to four. `blocked` is ambiguous on its own (it also means "review required"), so it reads as `failing` only alongside a standing approval and `pending` otherwise.

### org_role
`owner` · `admin` · `member`

### org_plan
`trial` · `active` · `cancelled`

---

## Multi-Org Architecture

All data tables include an `org_id` column (UUID, NOT NULL, FK → organizations) that scopes data to an organization. RLS policies enforce org isolation — authenticated users only see data belonging to their org (determined by JWT claims `org_id` and `org_role`).

**Key columns added by multi-org:**
- All 33 data tables: `org_id UUID NOT NULL REFERENCES organizations(id)`
- `user_profiles`: `default_org_id UUID REFERENCES organizations(id)` (users span orgs)

---

## Tables

### projects

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| name | TEXT | yes | — | Display name |
| key | TEXT | yes, unique | — | Uppercase prefix for ticket IDs (e.g., `RG`) |
| description | TEXT | no | — | |
| default_branch | TEXT | yes | `main` | |
| repository_url | TEXT | no | — | GitHub repo URL |
| next_ticket_number | INTEGER | yes | 1 | Atomic counter (managed by `create_ticket`) |
| org_id | UUID | yes | — | FK → organizations |
| archived_at | TIMESTAMPTZ | no | — | Soft delete |
| created_at | TIMESTAMPTZ | yes | now() | |
| updated_at | TIMESTAMPTZ | yes | now() | Auto-updated by trigger |

---

### epics

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| project_id | UUID | yes | — | FK → projects |
| name | TEXT | yes | — | |
| description | TEXT | no | — | |
| status | epic_status | yes | `planning` | |
| priority | priority_level | yes | `p2_medium` | |
| owner | TEXT | no | — | Plain name: `"dan"`, `"mb"` |
| acceptance_criteria | TEXT | no | — | Overall "done" definition |
| labels | TEXT[] | no | — | e.g., `'{frontend,auth}'` |
| planning_refs | JSONB | no | — | `{"prd": "docs/PRD.md", "tech_spec": "docs/TECH_SPEC.md"}` |
| org_id | UUID | yes | — | FK → organizations |
| created_by | TEXT | yes | `system` | |
| updated_by | TEXT | yes | `system` | |
| created_at | TIMESTAMPTZ | yes | now() | |
| updated_at | TIMESTAMPTZ | yes | now() | Auto-updated by trigger |

**Status auto-transitions (managed by plugin, not DB):**
- `planning` → `in_bloom`: when first child ticket moves to `in_bloom`
- `in_bloom` → `complete`: when all child tickets reach `harvest`
- Any → `weeded`: manual cancellation

---

### tickets

The core table. Everything revolves around this.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| project_id | UUID | yes | — | FK → projects |
| number | INTEGER | yes | — | Sequential per project |
| display_id | TEXT | yes, unique | — | `"{KEY}-{number}"` (e.g., `RG-42`) |
| title | TEXT | yes | — | Imperative voice |
| description | TEXT | no | — | |
| status | ticket_status | yes | `seeds` | |
| type | ticket_type | yes | — | |
| priority | priority_level | yes | `p2_medium` | |
| complexity | complexity_score | no | — | Predicted (set during tending) |
| actual_complexity | complexity_score | no | — | Real (set at merge) |
| assignee | TEXT | no | — | `"dan"`, `"mb"` |
| reviewer | TEXT | no | — | |
| epic_id | UUID | no | — | FK → epics |
| acceptance_criteria | TEXT | no | — | Checkbox list |
| summary | TEXT | no | — | One/two-sentence non-technical "what this delivers" — Slack body for created/status events. Set via `p_summary`, refreshed by `tend-ticket` |
| change_note | TEXT | no | — | One-line "what recently changed" display field; delivery text is frozen in `activity_log.value_was` at enqueue |
| implementation_plan | TEXT | no | — | Plan before work |
| implementation_notes | TEXT | no | — | Decisions during work |
| open_decisions | TEXT | no | — | Unresolved questions |
| labels | TEXT[] | no | — | `'{frontend,auth,api}'` |
| compliance_tags | TEXT[] | no | — | `'{soc2,iec_62304}'` |
| branch_name | TEXT | no | — | Git branch |
| pr_url | TEXT | no | — | GitHub PR URL |
| files_changed | TEXT | no | — | Key files touched |
| ai_implemented | BOOLEAN | yes | false | Set by `work-ticket` |
| org_id | UUID | yes | — | FK → organizations (inferred from project by `create_ticket`) |
| tended | BOOLEAN | yes | false | Set by `tend-ticket` |
| started_at | TIMESTAMPTZ | no | — | When work began |
| completed_at | TIMESTAMPTZ | no | — | When merged |
| created_by | TEXT | yes | `system` | |
| updated_by | TEXT | yes | `system` | |
| created_at | TIMESTAMPTZ | yes | now() | |
| updated_at | TIMESTAMPTZ | yes | now() | Auto-updated by trigger |

All field changes are auto-logged to `activity_log` by a trigger.

---

### ticket_relations

Single-direction storage. Query both directions via `get_ticket_relations()` RPC.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| source_ticket_id | UUID | yes | — | FK → tickets |
| target_ticket_id | UUID | yes | — | FK → tickets |
| relation_type | relation_type | yes | — | |
| org_id | UUID | yes | — | FK → organizations |
| created_by | TEXT | yes | `system` | |
| created_at | TIMESTAMPTZ | yes | now() | |

**Directionality (stored once, read both ways):**

| Stored | Source says | Target says |
|--------|-----------|------------|
| `blocks` | "A blocks B" | "B is blocked by A" |
| `relates_to` | "A relates to B" | "B relates to A" |
| `duplicates` | "A duplicates B" | "B is duplicated by A" |
| `caused_by` | "A was caused by B" | "B caused A" |

---

### comments

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| ticket_id | UUID | yes | — | FK → tickets |
| author | TEXT | yes | — | |
| body | TEXT | yes | — | |
| org_id | UUID | yes | — | FK → organizations |
| parent_comment_id | UUID | no | — | FK → comments (future threading) |
| created_at | TIMESTAMPTZ | yes | now() | |
| updated_at | TIMESTAMPTZ | yes | now() | Auto-updated by trigger |

---

### ticket_attachments

Files attached to a ticket (GH-66). Bytes live in the private `ticket-attachments` Storage bucket; the row is the source of record.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| ticket_id | UUID | yes | — | FK → tickets (CASCADE) |
| project_id | UUID | yes | trigger | Filled from the ticket by `ticket_attachments_fill_scope` (BEFORE INSERT); fails closed with `42501` when the ticket is not visible |
| org_id | UUID | yes | trigger / `get_user_org_id()` | Filled from the ticket |
| storage_path | TEXT | yes, unique | — | `{org_id}/{ticket_id}/{uuid}-{safe_file_name}` in the bucket |
| file_name | TEXT | yes | — | Original name shown in the UI |
| mime_type | TEXT | yes | — | |
| size_bytes | BIGINT | yes | — | `>= 0`; route cap 25 MiB, bucket `file_size_limit` 26214400 as backstop |
| created_by | TEXT | yes | `system` | Uploader's team username |
| created_at | TIMESTAMPTZ | yes | now() | |
| uploaded_at | TIMESTAMPTZ | no | — | NULL while the browser's signed upload is in flight; only stamped rows are listed. Reservations older than 1 h are pruned by the next list |

**RLS (per operation):** SELECT/INSERT use the tickets shape (`org_id = get_user_org_id() AND (is_org_admin_or_owner() OR user_has_project_access(project_id))`); INSERT additionally binds `created_by = current_team_username()` for members; UPDATE is the uploader only (it exists to stamp `uploaded_at`); DELETE is the uploader or an org admin/owner. `storage.objects` policies for the bucket key on the org folder AND `ticket_attachment_path_visible(name)` — the ticket in the path must be visible under tickets RLS — and DELETE also requires `owner_id = auth.uid()` or admin/owner.

**Upload flow (web app only, GH-66):** file bytes never pass through a route handler (Vercel caps route bodies at 4.5 MB). `POST /api/attachments` reserves the row and returns a signed upload URL; the browser calls `storage.uploadToSignedUrl`; `PATCH /api/attachments` verifies the object exists and stamps `uploaded_at`; `GET /api/attachments/download?id=` mints a 60 s signed URL. Each confirmed upload / delete writes `attachment_added` / `attachment_removed` via `log_ticket_change`.

**Plugin:** skills cannot upload yet — a CLI path would POST to the Storage REST endpoint with an API-key JWT and then insert the row (`created_by` must match `current_team_username()`, which resolves the key's `user_id` claim). Tracked as a follow-up.

---

### pull_requests

One row per **open** GitHub pull request (GH-88), the collection every ticket surface reads for "whose turn is it". Written only by the service role — the reconciler cron and the webhook receiver — so there are no INSERT/UPDATE/DELETE policies for authenticated sessions. A closed or merged PR runs the ticket back-sync (`pr_url` when unset; `in_review → harvest` on merge, both with `last_edited_source: "preserve"`) and its row is deleted.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| repo, number | TEXT, INTEGER | yes, unique together | — | `repo` is the lowercased repository name |
| url, title, author_login | TEXT | yes | — | |
| draft | BOOLEAN | yes | false | Derivation input |
| head_sha | TEXT | yes | — | Derivation input |
| requested_reviewer_login | TEXT | no | — | Derivation input |
| latest_review_state / _login / _commit_id | TEXT | no | — | Derivation inputs: the latest non-COMMENTED review. Storing them is what lets a webhook event re-derive the stage with no GitHub call |
| stage | pr_stage | yes | — | Derived |
| up_next_login | TEXT | yes | — | Derived — the GitHub login on the hook |
| checks_state | pr_checks_state | yes | `none` | From GitHub's `mergeable_state`, read alongside review state |
| mergeable_state | TEXT | no | — | GitHub's raw value, for context |
| comments_count | INTEGER | yes | 0 | |
| ticket_id | UUID | no | — | FK → tickets (SET NULL); the ticket named by `Implements GH-N` in the PR body |
| project_id | UUID | no | — | FK → projects; the project whose `repository_url` names the repo. NULL when none does |
| org_id | UUID | yes | — | FK → organizations. Unmatched repos take the single GitHub-connected org |
| pr_updated_at | TIMESTAMPTZ | yes | — | GitHub's `updated_at` |
| last_event_at | TIMESTAMPTZ | no | — | The webhook's out-of-order guard |
| synced_at | TIMESTAMPTZ | yes | now() | **The liveness stamp.** Bumped by every reconciler pass that confirms the row, changed or not. Readers treat a row older than 12 minutes as absent and render the plain ticket card — absent beats stale |
| created_at | TIMESTAMPTZ | yes | now() | |

**RLS:** SELECT only, the tickets shape — `org_id = get_user_org_id() AND (is_org_admin_or_owner() OR (project_id IS NOT NULL AND user_has_project_access(project_id)))`. Members see PRs for projects they have been granted; owners/admins see the whole org, including NULL-project rows.

**Sync (web app):** `/api/cron/sync-pull-requests` runs every 5 minutes (`web/vercel.json`) as the reconciler — a plain full pass over the 100 most recently updated open and merged PRs; writes nothing if a GitHub search fails, deletes a row only when a successful pass did not see the PR open (and nothing at all when the open search fills its page), and runs the `in_review → harvest` transition only for a merge newer than the previous successful run, so a ticket reopened after its PR merged is not re-harvested. `/api/webhooks/github` is the fast path — an org-level hook subscribed to Pull requests, Pull request reviews, Check suites and Statuses, verified by HMAC over the raw body (`GITHUB_WEBHOOK_SECRET`), answering 200 once verified because GitHub does not retry. A change to `stage`, `up_next_login` or `checks_state` broadcasts a contentless `pr-state` event on each open `board:{id}` channel; boards refetch through their own RLS-scoped poll. `/api/github-prs` (the Home widget) reads this table and makes no GitHub calls.

**Plugin:** read-only for skills. `GET /rest/v1/pull_requests?ticket_id=eq.{uuid}` shows a ticket's open PR state; skills never write here.

### pull_request_sync_state

A single row (`id = 1`) of sync health: `last_success_at`, `last_error`, `last_error_at`, `last_webhook_at`. Readable by org admins/owners only; the Home widget renders it as a muted line. `last_webhook_at` going cold while `last_success_at` keeps advancing means deliveries are silently failing — the one failure mode the reconciler masks.

---

### activity_log

Append-only audit trail. Auto-populated by triggers on ticket and epic updates.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| ticket_id | UUID | no | — | FK → tickets (null for epic-only) |
| epic_id | UUID | no | — | FK → epics (null for ticket-only) |
| actor | TEXT | yes | — | Who made the change |
| action | activity_action | yes | — | What happened |
| value_was | JSONB | yes | `{}` | Old values of changed fields only |
| org_id | UUID | yes | — | FK → organizations |
| notified_at | TIMESTAMPTZ | no | — | Slack outbox marker: NULL = pending delivery, set once dispatched (or dropped past the 24h cutoff) |
| created_at | TIMESTAMPTZ | yes | now() | |

**Constraint:** At least one of `ticket_id` or `epic_id` must be non-null.

**Notification enqueue:** an `updated` row whose `value_was` carries `{"notify": true, "change_note": "..."}` (written via `log_ticket_change`) is deliverable to Slack; trigger-generated `updated` rows are audit-only. See [common-operations §Lifecycle Notifications](common-operations.md#lifecycle-notifications).

**`value_was` pattern:** Stores only the old values of fields that changed. Current values live on the ticket/epic. Example: `{"status": "in_bloom", "pr_url": null}` means status *was* `in_bloom` and pr_url *was* null before this change.

**For list views:** Always use `select=actor,action,created_at` to avoid pulling large text blobs from `value_was`.

---

### organizations

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| name | TEXT | yes | — | Display name |
| slug | TEXT | yes, unique | — | URL-safe (`^[a-z0-9][a-z0-9-]*[a-z0-9]$`) |
| stripe_customer_id | TEXT | no | — | Stripe integration |
| stripe_subscription_id | TEXT | no | — | Stripe integration |
| plan | org_plan | yes | `trial` | |
| settings | JSONB | yes | `{}` | Org-level settings |
| created_at | TIMESTAMPTZ | yes | now() | |
| updated_at | TIMESTAMPTZ | yes | now() | Auto-updated by trigger |

---

### org_members

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| org_id | UUID | yes | — | FK → organizations |
| user_id | UUID | no | — | FK → auth.users (null for pending invites) |
| role | org_role | yes | `member` | |
| invite_email | TEXT | no | — | Email for pending invite |
| invited_at | TIMESTAMPTZ | no | — | |
| accepted_at | TIMESTAMPTZ | no | — | |
| created_at | TIMESTAMPTZ | yes | now() | |

**Constraints:** UNIQUE(user_id, org_id). At least one of user_id or invite_email must be non-null.

---

### org_project_access

Grants project-level access to org members (relevant for `member` role — admins/owners see all org projects).

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| org_member_id | UUID | yes | — | FK → org_members |
| project_id | UUID | yes | — | FK → projects |
| granted_by | TEXT | no | — | |
| created_at | TIMESTAMPTZ | yes | now() | |

**Constraint:** UNIQUE(org_member_id, project_id).

---

### org_api_keys

Opaque API keys (`ghk_live_*`) for org-scoped access. Keys are stored as sha256 hashes — the plaintext is shown once at creation and never stored.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| org_id | UUID | yes | — | FK → organizations |
| key_prefix | TEXT | yes | — | First 16 chars for identification |
| key_hash | TEXT | yes | — | sha256 hash of full key |
| label | TEXT | yes | — | Human-readable name |
| scopes | TEXT[] | yes | `{}` | Future: permission scopes |
| all_projects | BOOLEAN | yes | `true` | `true` = full org access; `false` = project-scoped (see api_key_projects) |
| created_by | UUID | no | — | FK → auth.users |
| last_used_at | TIMESTAMPTZ | no | — | Updated on each authenticate_key call |
| revoked_at | TIMESTAMPTZ | no | — | Set by revoke_org_key |
| expires_at | TIMESTAMPTZ | no | — | Optional expiry |
| created_at | TIMESTAMPTZ | yes | now() | |

---

### api_key_projects

Junction table linking API keys to specific projects. Only populated when `org_api_keys.all_projects = false`.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| key_id | UUID | yes | — | FK → org_api_keys (CASCADE) |
| project_id | UUID | yes | — | FK → projects (CASCADE) |
| created_at | TIMESTAMPTZ | yes | now() | |

**Constraint:** UNIQUE(key_id, project_id).

---

### slack_notification_rules

Per-project Slack routing. One rule = one channel (a Slack incoming webhook is channel-bound). Multiple rules per project coexist; one event fans out to every matching enabled rule. Members read, admins/owners write (RLS).

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| project_id | UUID | yes | — | FK → projects (CASCADE) |
| org_id | UUID | yes | `get_user_org_id()` | FK → organizations |
| name | TEXT | yes | — | e.g. `"Dev firehose"` |
| enabled | BOOLEAN | yes | true | |
| channel_label | TEXT | no | — | Display only — routing is the webhook |
| events | TEXT[] | yes | `{}` | Subset of: created, sprouted, in_bloom, in_review, changes_requested, harvest, weeded, updated, brainstorm (CHECK). `brainstorm` (GH-67) fires when a note is saved on the project; its message format is fixed and ignores `body_fields` |
| body_fields | TEXT[] | yes | `{}` | Subset of: summary, change_note, pr_url, actor, reviewer, priority, labels, complexity (CHECK) |
| webhook_set_at | TIMESTAMPTZ | no | — | Stamped by `set_/clear_rule_slack_webhook`; the URL itself lives in Vault (`slack_webhook_<rule_id>`), never selectable |
| created_by | TEXT | yes | `system` | |

**Skills never write this table** — it's managed in the web app's project Notifications settings.

---

### brainstorm_notes

Raw design-partner feedback captured in the web Brainstorm view (or via `POST /api/brainstorm` from a meeting / project quick-add). `/greenhouse:sow-feedback` reads notes and turns them into tickets. Members see and write only notes on projects they're granted; owners/admins see all (per-operation RLS, GH-53). NULL-project notes are hidden from members.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| org_id | UUID | yes | `get_user_org_id()` | FK → organizations |
| project_id | UUID | no | — | FK → projects (SET NULL). Rules are per project, so a NULL-project note is never announced |
| body | TEXT | yes | — | Markdown. Text-file attachments are pasted in under a `TEXT REFERENCE - {filename}` header; nothing is stored elsewhere |
| author | TEXT | yes | — | team_username; the API stamps the session identity |
| title | TEXT | no | — | Optional headline (GH-67). Shown on the card, in search, in Slack, and in sow-feedback's picker |
| source_attribution | TEXT | no | — | Who the feedback came from, free text — `"Priya @ Northwind via Sam @ Ridgeline"` (GH-67). Carried into tickets created from the note |
| dept | TEXT | no | — | `product` · `sales` · `customer` · `financial` (CHECK) (GH-67) |
| source_url | TEXT | no | — | Link to the source document; CHECK `^https?://` (GH-67) |
| tags | TEXT[] | no | — | Free text; the web form suggests every distinct tag in use, most recently used first |
| epic_id | UUID | no | — | FK → epics. Retained for old rows; nothing writes it since GH-67 |
| assignee | TEXT | no | — | Retained for old rows; nothing writes it since GH-67 |
| customer_id | UUID | no | — | FK → customers (SET NULL) (GH-76). A trigger rejects (23514) a customer from another project; clearing the note's project clears it |
| summary | TEXT | no | — | Short digest (GH-76). Shown on the collapsed card in place of the body excerpt; editable in the web edit mode |
| archived | BOOLEAN | yes | false | Soft delete |
| notified_at | TIMESTAMPTZ | no | — | Slack outbox marker (GH-67). NULL = pending; the dispatch cron stamps it once every matching `brainstorm` rule delivered, and `get_deliverable_brainstorm_notifications()` retires anything still pending after 24h. Only INSERTs are ever pending — edits never re-notify |
| created_at | TIMESTAMPTZ | yes | now() | |
| updated_at | TIMESTAMPTZ | yes | now() | Trigger |

**Skills read this table** (sow-feedback) but never write it — capture happens in the web app.

---

### customers

Customers and design partners a project's brainstorm notes are about (GH-76). A name list, not a CRM — the structured record lives in Close, and this is deliberately not the `companies` table (RRS's own sales pipeline). Managed on the web Customers page or inline from the brainstorm composer. Same per-operation RLS as `brainstorm_notes`: members read and write only customers on granted projects; owners/admins see the org.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| org_id | UUID | yes | `get_user_org_id()` | FK → organizations |
| project_id | UUID | yes | — | FK → projects (CASCADE). A customer never crosses projects |
| name | TEXT | yes | — | CHECK not blank. Unique per project case-insensitively (`(project_id, lower(name))`) |
| created_by | TEXT | yes | `system` | team_username; the API stamps the session identity |
| created_at | TIMESTAMPTZ | yes | now() | |
| updated_at | TIMESTAMPTZ | yes | now() | Trigger |

---

### brainstorm_triage

One row per sowing of a brainstorm note (`/greenhouse:sow-feedback`). A note with ≥1 row is **Planted**, else **Raw**.

| Column | Type | Required | Default | Notes |
|--------|------|----------|---------|-------|
| id | UUID | PK | auto | |
| note_id | UUID | yes | — | FK → brainstorm_notes (CASCADE) |
| org_id | UUID | yes | `get_user_org_id()` | FK → organizations |
| triaged_by | TEXT | yes | — | Who sowed |
| triaged_at | TIMESTAMPTZ | yes | now() | |
| tickets_touched | UUID[] | yes | `{}` | Tickets created/updated by this sowing |
| dropped | JSONB | yes | `[]` | `[{"requirement", "reason"}]` per non-actioned item |
| action_summary | TEXT | no | — | e.g. `"2 created, 1 updated, 1 dropped"` |

---

## RPC Functions

### create_ticket

Atomic ticket creation with auto-generated sequential ID.

```
POST /rest/v1/rpc/create_ticket
{
  "p_project_id": "uuid",
  "p_title": "Add password reset flow",
  "p_type": "feature",
  "p_priority": "p1_high",           -- default: p2_medium
  "p_status": "seeds",               -- default: seeds
  "p_description": "...",            -- optional
  "p_acceptance_criteria": "...",    -- optional
  "p_assignee": "dan",              -- optional
  "p_reviewer": "mb",            -- optional
  "p_epic_id": "uuid",              -- optional
  "p_complexity": "8",              -- optional
  "p_labels": ["auth", "api"],      -- optional
  "p_compliance_tags": ["soc2"],    -- optional
  "p_created_by": "dan",            -- default: system
  "p_rank": "0|hzzzzz:",            -- optional (LexoRank manual order)
  "p_summary": "..."                -- optional but always set it: plain-English Slack body
}
```

**Returns** (~80 tokens):
```json
{"id": "uuid", "display_id": "RG-15", "number": 15, "title": "Add password reset flow", "status": "seeds", "created_at": "2026-03-01T10:30:00Z"}
```

Auto-logs creation to `activity_log`.

---

### get_ticket_context

Everything needed to work on a ticket in one call.

```
POST /rest/v1/rpc/get_ticket_context
{"p_display_id": "RG-15"}
```

**Returns** (~400-500 tokens): Full ticket fields + epic info + bidirectional relations + last 5 comments. Returns `null` if ticket not found.

```json
{
  "id": "uuid", "display_id": "RG-15", "title": "Add password reset flow",
  "status": "in_bloom", "type": "feature", "priority": "p1_high",
  "complexity": "8", "assignee": "dan", "reviewer": "mb",
  "description": "...", "acceptance_criteria": "...",
  "implementation_plan": "...", "implementation_notes": null, "open_decisions": null,
  "labels": ["auth"], "branch_name": "dt/rg-15-password-reset", "pr_url": null,
  "epic": {"id": "uuid", "name": "User Authentication", "status": "in_bloom"},
  "relations": [
    {"relation_id": "uuid", "relation_type": "blocks", "direction": "blocked_by",
     "related_display_id": "RG-12", "related_title": "Email service", "related_status": "in_bloom"}
  ],
  "comments": [
    {"author": "dan", "body": "Starting implementation", "created_at": "2026-03-01T11:00:00Z"}
  ]
}
```

---

### get_ticket_relations

All relations for a ticket with direction resolved.

```
POST /rest/v1/rpc/get_ticket_relations
{"p_ticket_id": "uuid"}
```

**Returns:** Array of `{relation_id, relation_type, direction, related_ticket_id, related_display_id, related_title, related_status}`.

---

### resolve_display_ids

Batch-resolve display IDs to UUIDs. Eliminates N+1 lookups for relation wiring.

```
POST /rest/v1/rpc/resolve_display_ids
{"p_display_ids": ["RG-15", "RG-8"]}
```

**Returns:** `[{"display_id": "RG-15", "id": "uuid"}, {"display_id": "RG-8", "id": "uuid"}]`

---

### log_ticket_change

Manual activity log entry for actions not covered by auto-triggers.

```
POST /rest/v1/rpc/log_ticket_change
{"p_ticket_id": "uuid", "p_actor": "dan", "p_action": "commented", "p_changes": {}}
```

**Returns:** UUID of the created log entry.

---

### ticket_lifecycle_stats

One row per visible ticket, reducing its `status_changed` history — what the
Reports page builds review rounds and PR cycle time from (GH-75).

```
POST /rest/v1/rpc/ticket_lifecycle_stats
{"p_project_id": "uuid"}        # omit or null for every project the caller can see
```

**Returns:** `ticket_id`, `review_rounds`, `first_in_bloom_at`,
`first_in_review_at`, `harvested_at`, `weeded_at`.

`first_in_bloom_at` and `harvested_at` are the real transition times, which is
what lets a reader recover a `started_at` or `completed_at` that was written as a
bare date and coerced to midnight UTC.

Three things to know before using it:

- **`activity_log.value_was` holds OLD values.** A `status_changed` row records
  the status the ticket *left*, not the one it entered. The status entered at row
  *i* is row *i+1*'s `value_was.status`, closed by the ticket's current status —
  that `LEAD` walk is why the reduction lives in SQL rather than in TypeScript.
- **It returns a SET, so PostgREST's `max_rows = 1000` applies.** Page it with
  `Range` headers exactly as you would a table read. Unpaged it stops silently at
  the thousandth ticket and every derived number is quietly wrong.
- **`SECURITY INVOKER`** — `activity_log` RLS applies to the caller. Scoping runs
  through the `tickets` join, not `activity_log.project_id`.

Ordering is `(created_at, seq)`. `activity_log.seq` is an identity column added
by GH-75: `created_at` defaults to `now()`, which inside a transaction is the
*transaction* timestamp, so two status changes committed together share it
exactly and the window order between them was arbitrary. `get_deliverable_
notifications` does the same walk and carries the same tiebreaker.

---

### mint_org_key

Create a new org API key. Admin/owner only.

```
POST /rest/v1/rpc/mint_org_key
{"p_org_id": "uuid", "p_label": "CI/CD Key", "p_all_projects": true, "p_project_ids": []}
```

- `p_all_projects`: `true` for full org access (includes future projects), `false` for project-scoped.
- `p_project_ids`: required when `p_all_projects` is `false` — array of project UUIDs (must belong to the org).

**Returns:** `{"key": "ghk_live_...", "key_id": "uuid"}` — the plaintext key is shown once, never stored.

---

### authenticate_key

Exchange an org API key for a short-lived JWT (1 hour). Callable by anon role.

```
POST /rest/v1/rpc/authenticate_key
{"p_api_key": "ghk_live_..."}
```

**Returns:** `{"token": "eyJ...", "org_id": "uuid", "expires_at": "2026-03-19T11:00:00Z"}`

JWT claims include `org_id`, `key_id`, and:
- **All-projects keys:** `org_role: "service"` — full org access.
- **Project-scoped keys:** `org_role: "api_key"` + `project_ids: ["uuid", ...]` — RLS enforces project boundaries.

---

### revoke_org_key

Revoke an org API key. Admin/owner only.

```
POST /rest/v1/rpc/revoke_org_key
{"p_key_id": "uuid"}
```

---

## Views

### epic_progress

Epic with child ticket status breakdown.

```
GET /rest/v1/epic_progress?project_id=eq.{uuid}&status=neq.weeded
```

Returns: `epic_id`, `name`, `status`, `priority`, `owner`, `project_id`, `org_id`, `total_tickets`, `seeds_count`, `sprouted_count`, `in_bloom_count`, `in_review_count`, `changes_requested_count`, `harvest_count`, `weeded_count`

---

### blocked_tickets

Tickets with unresolved blockers (excludes harvest/weeded blockers).

```
GET /rest/v1/blocked_tickets?project_id=eq.{uuid}&select=display_id,title,status,priority,blocked_by&limit=50
```

Returns: `ticket_id`, `display_id`, `title`, `status`, `priority`, `project_id`, `org_id`, `blocked_by` (JSONB array with `display_id`, `title`, `status` per blocker)

---

### project_summary

Project-level ticket counts by status.

```
GET /rest/v1/project_summary?project_id=eq.{uuid}&select=project_id,name,key,seeds_count,sprouted_count,in_bloom_count,in_review_count,changes_requested_count
```

Returns: `project_id`, `name`, `key`, `org_id`, `total_tickets`, `seeds_count`, `sprouted_count`, `in_bloom_count`, `in_review_count`, `changes_requested_count`, `harvest_count`, `weeded_count`

---

## Triggers (Automatic)

1. **update_updated_at** — Applied to projects, epics, tickets, comments. Auto-updates `updated_at` on every UPDATE.
2. **trigger_log_ticket_change** — After UPDATE on tickets. Compares all fields, logs changes to `activity_log` with `value_was` pattern. Action is `status_changed` if status changed, else `updated`.
3. **trigger_log_epic_change** — After UPDATE on epics. Same pattern. Action is `epic_status_changed` if status changed, else `epic_updated`.

4. **handle_new_user** — After INSERT on auth.users. Creates user_profiles row, accepts pending org invite (if matching email), otherwise creates a personal org.
5. **custom_access_token_hook** — JWT hook. Injects `org_id` and `org_role` into JWT claims from `user_profiles.default_org_id` and `org_members.role`.

Skills do not need to manually log ticket/epic updates — the triggers handle it automatically. Use `log_ticket_change` RPC only for manual entries (e.g., `commented`, `relation_added`).

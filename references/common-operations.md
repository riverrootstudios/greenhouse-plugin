# Common Operations

Shared patterns referenced by multiple skills. Skills link here instead of duplicating logic.

---

## Session Authentication

**Used by:** Every skill that makes Greenhouse API calls (Step 0, after sync queue replay)

Before any API calls, ensure a fresh session JWT:

```bash
eval "$(gh-jwt)"
```

[`gh-jwt`](../bin/gh-jwt) handles the full authentication flow — exchanges `GREENHOUSE_API_KEY` for a session JWT via the `authenticate_key()` RPC, caches the token at `~/.greenhouse/jwt` (mode 600), and auto-refreshes within 60s of expiry — or when a user-bound token is missing the `team_username` claim, so a token minted before a claim shipped can't leave the export empty. Calling it again is cheap when the cached token is still valid (no network), so re-run it freely before any sequence of API calls — it's the only mechanism that survives the shell-state loss between Claude Code Bash tool invocations.

All subsequent API calls use:
```
curl --connect-timeout 5 --max-time 15 --retry 2 \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}"
```
The timeout/retry flags apply to every Greenhouse `curl`, shown or not (see [greenhouse-api §Standard curl flags](greenhouse-api.md#standard-curl-flags)).

The eval exports six variables: `GREENHOUSE_URL`, `GREENHOUSE_PUBLIC_KEY`, `GREENHOUSE_JWT`, **`GREENHOUSE_ORG_ID`**, **`GREENHOUSE_USER_ID`**, and **`GREENHOUSE_TEAM_USERNAME`**. The last three are read off the token's own claims — use them rather than deriving any of those values locally. `GREENHOUSE_USER_ID` is empty for a legacy org key and set for any user-bound token, which is what separates those two cases when `GREENHOUSE_TEAM_USERNAME` comes back empty (see [conventions §Current user resolution](../skills/conventions/SKILL.md#current-user-resolution)).

### org_id on writes

Every data table is `org_id NOT NULL` with an RLS `WITH CHECK` policy, so **any raw `POST /rest/v1/{table}` must carry `org_id`** or the insert fails with `42501` (`new row violates row-level security policy`). Use `${GREENHOUSE_ORG_ID}` from the eval above:

```bash
-d "{\"...\": \"...\", \"org_id\": \"${GREENHOUSE_ORG_ID}\"}"
```

Rules:
- **Never hand-roll the JWT decode.** Base64url payloads need `=` padding restored before `base64 -d`; macOS/BSD `base64` rejects unpadded input and yields an empty string, so the insert fails with a confusing RLS error rather than a decode error. `gh-jwt` does the padding — use its export.
- **Never read org_id from CLAUDE.md** when a token is in hand. The JWT's claim is what RLS actually evaluates; a config block can disagree with the token you're authenticated as.
- **RPCs don't need it.** `create_ticket` and friends infer `org_id` server-side from the project. This applies only to direct table writes.
- Tables also carry a DB-level `DEFAULT get_user_org_id()` (GH-36) as a backstop, but keep sending `org_id` explicitly — the default returns NULL under `service_role`, and an explicit value keeps failures descriptive.

See [references/greenhouse-api.md](greenhouse-api.md) for the underlying authentication flow if you need to debug or extend it.

### identity on writes

Three columns are **identity-bound** — RLS requires the value to be the caller's
own `team_username`, and a member's write is rejected with `42501` when it isn't:

| Column | Policy |
|--------|--------|
| `time_entries.owner` | `time_entries_insert` / `_update` / `_delete` (GH-53) |
| `claude_usage_daily.user_name` | `claude_usage_daily_insert` / `_update` |
| `claude_usage_projects.user_name` | `claude_usage_projects_insert` / `_update` |

Always send `${GREENHOUSE_TEAM_USERNAME}` from the eval above:

```bash
-d "{\"owner\": \"${GREENHOUSE_TEAM_USERNAME}\", \"...\": \"...\"}"
```

Rules:
- **Never send a GitHub login, git author name, or a Team-table name or initials.** None of them is an identity; this is an attribution key. They are frequently different strings for the same person, and the failure is invisible in testing because `is_org_admin_or_owner()` accepts *any* `owner` value for owners and admins — only members get the 42501.
- **Empty means stop, not guess.** An empty export is a token with no identity: either a legacy org key, or a member whose profile has no `team_username` yet. Report it (see [conventions §Current user resolution](../skills/conventions/SKILL.md#current-user-resolution) for the two messages) and skip the write.
- **Reads are not identity-bound.** Filtering by `owner=eq.${GREENHOUSE_TEAM_USERNAME}` is about scoping the result set, not permission — project-scoped reads are visible to the whole project by design.

**When a 42501 comes back anyway,** don't surface the bare 403 — name the column you sent and which gate failed. The gates differ by table, so report only the ones that table actually has:

`time_entries` (column `owner`):

```
Time entry rejected (42501). Sent owner={what you sent},
your Greenhouse identity is {GREENHOUSE_TEAM_USERNAME}.
  • owner mismatch      → the two differ; send the identity value
  • no project access   → your token's project_ids don't include {project}
                          (ask an admin to grant it in web → Projects)
  • tracking disabled   → {project}.time_tracking_enabled is false
```

`claude_usage_daily` / `claude_usage_projects` (column `user_name`) — these gate on
`org_id = get_user_org_id() AND (is_org_admin_or_owner() OR user_name = current_team_username())`
only. There is no project-access predicate (usage rows are upserted before the
path→project linkage fills `project_id`) and no time-tracking toggle, so don't
report either:

```
Usage upsert rejected (42501). Sent user_name={what you sent},
your Greenhouse identity is {GREENHOUSE_TEAM_USERNAME}.
  • user_name mismatch  → the two differ; send the identity value
  • org mismatch        → the row's org_id isn't your token's org
                          (send ${GREENHOUSE_ORG_ID}, not a hard-coded id)
```

---

## Resolve Ticket Context

**Used by:** `work-ticket`, `tend-ticket`, `create-ticket`, `review-pr`, `fix-review-feedback`, `health-check`

Fetch the full context for a ticket by display ID. Returns ticket fields, epic details, relations, and the last 5 comments in a single call (~400 tokens).

**Once per ticket per flow.** If you already hold this ticket's context from the calling skill, reuse it; otherwise call `get_ticket_context`. A skill handing off to another (work-ticket → open-pr, review-pr → compliance-check) passes the context along rather than re-fetching. Re-fetch only when you need state another actor may have changed since (e.g. the status right before a guarded PATCH — and the PATCH filter guard covers that anyway).

```bash
curl -s --connect-timeout 5 --max-time 15 --retry 2 -X POST "${GREENHOUSE_URL}/rest/v1/rpc/get_ticket_context" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"p_display_id\": \"{TICKET-ID}\"}"
```

The response includes the ticket `id` (UUID) needed for all subsequent operations (PATCH, relations, comments).

**Auto-pick (no ticket ID provided):** Query for the next actionable ticket:
```
GET /rest/v1/tickets?project_id=eq.{id}&tended=is.false&status=in.(sprouted,seeds)&order=priority.asc,created_at.asc&limit=1&select=display_id,title,status,priority,type
```
Then confirm with user and fetch full context via `get_ticket_context`.

---

## Posting Comments and PATCHing Multi-line Ticket Fields

**Used by:** `tend-ticket`, `create-ticket`, `fix-review-feedback`, `review-pr` — any skill that writes markdown content (acceptance criteria, descriptions, comment bodies) to Greenhouse.

The naive shape `jq -n --arg body "$MULTILINE_VAR" '{body: $body}'` **fails** when the value contains literal newlines:

```
jq: parse error: Invalid string: control characters from U+0000 through U+001F must be escaped
```

`--arg` is for short single-line strings only. Use this pattern for anything that may contain newlines:

```bash
# 1. Write the multi-line body to a temp file FIRST. Never inline into --arg.
cat > /tmp/gh-body.md <<'EOF'
{multi-line markdown content here, including blank lines, bullets, etc.}
EOF

# 2. Build the JSON payload to a temp file: --rawfile for multi-line fields,
#    --arg only for short single-line fields (ids, usernames, statuses).
jq -n \
  --arg ticket_id "{uuid}" \
  --arg org_id    "${GREENHOUSE_ORG_ID}" \
  --arg author    "${GREENHOUSE_TEAM_USERNAME}" \
  --rawfile body  /tmp/gh-body.md \
  '{ticket_id: $ticket_id, org_id: $org_id, author: $author, body: $body}' \
  > /tmp/gh-payload.json

# 3. POST directly from the payload file. Do NOT use process substitution.
curl -sS --connect-timeout 5 --max-time 15 --retry 2 -X POST "${GREENHOUSE_URL}/rest/v1/comments" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  --data-binary @/tmp/gh-payload.json | jq '{id, ticket_id, author, created_at}'
```

**Rules:**
- `org_id` is required on the insert — RLS rejects a comment without it. Use `${GREENHOUSE_ORG_ID}` (see [org_id on writes](#org_id-on-writes)); never hand-roll a JWT decode.
- Use `--rawfile` for any field that *might* contain newlines: `body`, `description`, `acceptance_criteria`, `open_decisions`, `summary`, `change_note`, `implementation_plan`. Use `--arg` only for short single-line strings.
- Always write the JSON payload to a file and POST with `--data-binary @/tmp/file.json`. Do **not** echo into curl, do **not** use `--data-binary @<(printf ...)` (process substitution can confuse jq's stdin detection and silently produces garbage).
- PATCH uses the same shape, just `curl -sS --connect-timeout 5 --max-time 15 --retry 2 -X PATCH "${GREENHOUSE_URL}/rest/v1/tickets?display_id=eq.{ID}"` and add `-H "Prefer: return=representation"` if you want the updated row back.
- For PATCH bodies with multiple multi-line fields (e.g. tending updates `acceptance_criteria` + `description`), write each to its own temp file and use multiple `--rawfile` flags.

**Verification after a write:** the RPC `get_ticket_context` is convenient but does not return every column. To confirm fields like `tended` or `updated_by`, query the table directly:
```bash
curl -sS --connect-timeout 5 --max-time 15 --retry 2 "${GREENHOUSE_URL}/rest/v1/tickets?display_id=eq.{ID}&select=display_id,status,tended,updated_by" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}" | jq '.[0]'
```

---

## Blocker Check

**Used by:** `work-ticket`, `tend-ticket`

For the ticket being worked on:

1. Use the relations already in the ticket's `get_ticket_context` — if you already hold this ticket's context from the calling skill, reuse it; otherwise call `get_ticket_context` (not `get_ticket_relations`, which returns a subset of the same thing). Look for entries with `direction = 'blocked_by'` (their `relation_type` is `blocks`).
2. A blocker whose `related_status` is `harvest` or `weeded` is **resolved** — it no longer blocks. Leave the relation in place: it records that the blocker once held this ticket up, and the web surfaces show it struck through (GH-104). Never delete a relation because its blocker finished.
3. If any blocker is still open, list them with their statuses. Offer:
   1. Work on a blocker instead
   2. Unlink a blocker that never applied (`DELETE /rest/v1/ticket_relations?id=eq.{relation_id}`) and proceed — only on the user's say-so
   3. Proceed anyway (stacked branch off the blocker's branch, if applicable)
4. If every blocker is resolved (or there are none): proceed normally

Alternatively, use the `blocked_tickets` view for a project-wide blocker overview:
```
GET /rest/v1/blocked_tickets?project_id=eq.{uuid}&select=display_id,title,status,priority,blocked_by&order=priority.asc&limit=50
```

---

## Quality Gate

**Used by:** `work-ticket`, `open-pr`, `fix-review-feedback`, `health-check`

Run the quality gate commands. Check the Common Commands section in CLAUDE.md for project-specific commands. Standard gate:

```bash
pnpm install --frozen-lockfile
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

If a step fails, fix the issue and re-run the full gate (don't skip earlier steps). After 3 failed attempts on the same error, stop and report to the user. For autonomous mode (`work-ticket`): revert the ticket to `sprouted` after 3 failures.

---

## Resolve Base Branch

**Used by:** every step that depends on the base — `work-ticket` (branch cut, resume rebase, self-review diff), `open-pr` (`--base`, preflight rebase), `fix-review-feedback` (conflict rebase), `review-pr` (`--self` diff), `merge-pr` (target), `health-check` (branch comparison), `create-ticket` (epic branch cut).

Never name a branch in a skill step. Resolve `{base}` here, first match wins:

1. **Named in the session** — the user said which base to use ("target staging", "branch off release-2").
2. **The open PR's base** — when a PR exists for this branch: `gh pr view --json baseRefName --jq .baseRefName`.
3. **The epic branch** — only when the ticket has an explicitly planned epic with `epic_branch` set (see [conventions §Epic Usage](../skills/conventions/SKILL.md#epic-usage)).
4. **`integration_branch`** in the repo's `greenhouse` fence in CLAUDE.md.
5. **`dev` if it exists** — `git ls-remote --heads origin dev` returns a ref → `dev`; otherwise `main`.

`dev` is a default, not a rule: a repo with no `dev` and no fence key resolves to `main` and works unchanged. Ticket PRs squash into `{base}`; `main` receives merge commits from the integration branch at release (see the [release skill](../skills/release/SKILL.md)).

---

## Inline Rebase

**Used by:** `work-ticket` (when resuming a branch), `open-pr` (preflight), `fix-review-feedback` (conflicts)

1. `git fetch origin {base} && git rebase origin/{base}` — `{base}` from [Resolve Base Branch](#resolve-base-branch)
2. If conflicts: resolve, stage, `git rebase --continue`
3. Run quality gate after rebase
4. If previously pushed: `git push --force-with-lease origin {branch-name}`

---

## Worktrees

**Used by:** `work-ticket` (Step 4), `merge-pr` (cleanup), `health-check` (Step 2)

Claude Code can create git worktrees on its own. Skills never do: a worktree is created only after the user says yes to one.

**Detect one:** the cwd is a worktree when `git rev-parse --git-common-dir` and `git rev-parse --git-dir` differ. `git worktree list --porcelain` lists every worktree with its `branch`.

**One local database per machine.** Every worktree shares the same local Supabase stack, but each carries only its own branch's migrations. Before `supabase db reset` or `supabase migration up` from a worktree, warn: *"This worktree has {branch}'s migrations only — resetting the shared local DB here drops anything the main checkout's branch added. Continue?"*

**Removing one:** `git worktree remove {path}`. When `git -C {path} status --porcelain` is non-empty, confirm first, naming the path: *"{path} has uncommitted changes — remove it anyway?"* Never `--force` without that yes.

---

## Out-of-Scope Findings

**Used by:** `work-ticket` (Scope Discovery), `fix-review-feedback`

A skill never files a ticket on its own. Work found outside the current acceptance criteria goes into a findings list instead:

1. Note each finding as it comes up — one line: what, where (`file:line`), why it's out of scope.
2. Keep working the original scope.
3. At the end of the run, show the list and add it to the ticket's closing comment:
   ```
   ### Out of scope — not filed
   1. {finding} ({file:line})
   2. ...
   Say "file 2" (or "file all") and I'll create tickets for them.
   ```
4. Create a ticket (via [create-ticket](../skills/create-ticket/SKILL.md)) only after the user says yes to a specific item.

An empty list is omitted, not printed as "none".

---

## PR Ticket ID Extraction

**Used by:** `review-pr`, `health-check`, `compliance-check`

Parse the PR description for the `Implements {TICKET-ID}` pattern (e.g., `Implements RG-42`).

If found:
- Look up the ticket via `POST /rest/v1/rpc/get_ticket_context` with `{"p_display_id": "{TICKET-ID}"}`

If not found:
- Prompt for the ticket ID: *"This PR doesn't reference a Greenhouse ticket. Can you provide the ticket ID? (Required for compliance.)"*

---

## PR State Guard

**Used by:** `review-pr`, `fix-review-feedback`, `merge-pr` — any skill that acts on an existing PR.

Run this **immediately after resolving the PR number, before any review, implementation, or Greenhouse write.** A PR that is already closed or merged must not be reviewed, commented on, or worked against — the work has landed or been abandoned, and acting on it writes stale state to GitHub and Greenhouse.

```bash
gh pr view {number} --json state,isDraft,mergedAt,mergeCommit,closedAt,author,title,url \
  --jq '{state, isDraft, mergedAt, closedAt, title, author: .author.login, sha: .mergeCommit.oid}'
```

`state` is one of `OPEN`, `MERGED`, `CLOSED`. **Request the `state` field explicitly** — it is easy to omit from a longer `--json` list, and its absence reads as "no problem found" rather than "never checked."

`mergeCommit` and `author` are objects — read `.mergeCommit.oid` and `.author.login`, not the bare fields. Both are `null` on an open PR.

### If `state` is not `OPEN` — stop

Report what happened and stop. Do not offer to review the merge commit, do not propose alternative PRs, do not write to Greenhouse:

```
PR #{number} is {MERGED|CLOSED} — nothing to do here.

{title}
{merged|closed} by @{github_login} on {date}
{merge commit {sha} — only when merged}
{TICKET-ID} is currently {status} in Greenhouse.
```

Then end the skill. The user asked to act on a PR that is no longer actionable; the useful response is an accurate statement of where things stand, not a menu of substitutes. If they want something else, they will say so.

**Exception — `--self` mode:** `review-pr --self` reviews the working branch before a PR exists. Skip the guard entirely; there is no PR to check.

### If `isDraft` is true — warn, then ask

Draft PRs are reviewable, but the author may not be ready:

> "PR #{number} is still a draft. Review it anyway?"

Proceed on confirmation; stop otherwise.

### Ticket status cross-check

When the PR is open but the linked ticket is already `harvest`, the two have drifted:

> "PR #{number} is open, but {TICKET-ID} is already `harvest` in Greenhouse. That usually means the ticket was harvested against a different PR. Worth checking before I continue — proceed anyway?"

---

## CI on the Current Head

**Used by:** `review-pr` (Step 1), `merge-pr` (Step 3)

`gh pr checks` reports the **last** run, not a run on the current head. A `CONFLICTING` PR makes GitHub skip every `pull_request` run, so `gh pr checks` keeps showing the last green one while newer commits go untested.

```bash
gh pr view {number} --json headRefOid,headRefName,mergeable \
  --jq '{head: .headRefOid, branch: .headRefName, mergeable}'
gh run list --branch {headRefName} --event pull_request --limit 1 \
  --json databaseId,headSha,status,conclusion
```

| Condition | CI reads as | Effect |
|-----------|-------------|--------|
| `mergeable` is `CONFLICTING` | **unverified** — GitHub skipped the runs | Blocking. Never report "passing" |
| `headSha` matches `headRefOid`, `status` is not `completed` | **pending** | Wait and re-check; never fall back to an older run |
| latest run's `headSha` ≠ `headRefOid` | **unverified** | Blocking. Name both SHAs and the run id: *"CI last ran on {headSha} (run {databaseId}); the PR head is {headRefOid}."* |
| SHAs match, `conclusion` is `success` | passing | — |
| SHAs match, any other `conclusion` | failing | Blocking |

The run list is not filtered by `status`, so a run still in progress on the head is the latest run and reads as **pending** — a `--status completed` filter would skip it and surface the older run instead.

---

## Session Timer

**Used by:** `work-ticket` (start). Stopping is handled automatically by the idle-shutoff sweep in production (closes any running entry whose `last_heartbeat_at` is older than 1 hour). Skills do not stop timers manually.

### Step 0 Heartbeat — Every Skill

Every skill that runs `eval "$(gh-jwt)"` must also tick the session timer once during preflight. Append the `gh-heartbeat` helper after the JWT eval:

```bash
gh-heartbeat
```

`gh-heartbeat` ships in [plugin/bin/](../bin/gh-heartbeat). It POSTs to `tick_session_timer`, which resolves the caller server-side from the JWT (web sessions via `auth.uid()`, CLI tokens via the `user_id` claim) — no local GitHub-login mapping, so it works for any org member, not just the Team table. Silent on success; a failure prints one stderr line naming the HTTP status but never aborts the calling skill.

This bumps `last_heartbeat_at` on every running entry owned by the user, keeping the idle-shutoff sweep at bay while work is happening. The RPC is idempotent and a no-op when no timers are running.

### Start or Resume Timer (work-ticket only)

The `owner` on every call below is `${GREENHOUSE_TEAM_USERNAME}` from the Step 0 eval — the caller's Greenhouse attribution key, never a GitHub login or a Team-table name (see [identity on writes](#identity-on-writes)). If it's empty, say so and skip the timer rather than inventing a name; the INSERT would 42501 for any member.

Look up a running entry **scoped to this ticket**, never "any running entry" — parallel timers exist:

```bash
curl -s --connect-timeout 5 --max-time 15 --retry 2 "${GREENHOUSE_URL}/rest/v1/time_entries?owner=eq.${GREENHOUSE_TEAM_USERNAME}&ticket_id=eq.{ticket_uuid}&end_time=is.null&select=id,description" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}"
```

**If a running entry for this ticket exists** — refresh `last_heartbeat_at` only (description and start_time stay put):

```bash
curl -s --connect-timeout 5 --max-time 15 --retry 2 -X PATCH "${GREENHOUSE_URL}/rest/v1/time_entries?id=eq.{entry_id}" \
  -H "Content-Type: application/json" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -d '{"last_heartbeat_at": "{iso_now}"}'
```

**If no running entry for this ticket** — first check the project's time-tracking toggle. Projects can opt out of collection (GH-53); a disabled project must skip the timer *and say so*, never fail silently:

```bash
curl -s --connect-timeout 5 --max-time 15 --retry 2 "${GREENHOUSE_URL}/rest/v1/projects?id=eq.{project_uuid}&select=time_tracking_enabled" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}"
```

If `time_tracking_enabled` is `false`, tell the user — *"Time tracking is disabled for {project}; no session timer started."* — and continue the skill without a timer. (The INSERT below would be rejected by RLS anyway; checking first keeps the message friendly.)

Otherwise INSERT a new entry. Set `project_id` from the ticket's project so the entry appears in per-project breakdowns, `owner` from `${GREENHOUSE_TEAM_USERNAME}` (see [identity on writes](#identity-on-writes)), and `org_id` from `${GREENHOUSE_ORG_ID}` so RLS accepts the write (see [org_id on writes](#org_id-on-writes)):

```bash
curl -s --connect-timeout 5 --max-time 15 --retry 2 -X POST "${GREENHOUSE_URL}/rest/v1/time_entries" \
  -H "Content-Type: application/json" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Prefer: return=representation" \
  -d "{\"owner\": \"${GREENHOUSE_TEAM_USERNAME}\", \"description\": \"Working on {TICKET-ID}: {ticket_title}\", \"ticket_id\": \"{ticket_uuid}\", \"project_id\": \"{project_uuid}\", \"start_time\": \"{iso_now}\", \"org_id\": \"${GREENHOUSE_ORG_ID}\"}"
```

`~/.greenhouse/session-timer.json` is an optional cache for the most recent work-ticket entry; skills tolerate its absence by falling back to the DB lookup above keyed by `ticket_id`. Write it after INSERT:

```json
{ "entry_id": "{id}", "ticket_id": "{TICKET-ID}", "started_at": "{iso_now}" }
```

---

## Lifecycle Notifications

**Used by:** no skill directly — this documents why skills must NOT send notifications.

Slack delivery is entirely **trigger + cron**, never skill-driven. The `log_ticket_changes` trigger records every ticket INSERT and UPDATE into `activity_log` (the outbox — `notified_at IS NULL` means pending); a Vercel cron (`/api/cron/dispatch-notifications`, every 2 min) drains it and POSTs to each project's `slack_notification_rules` webhooks.

- **Never call Slack or format a message from a skill.** Ticket creations and status changes notify automatically — a skill that PATCHes `status` has already done everything needed.
- **Deliberate content-change notifications** (e.g. sow-feedback updating acceptance criteria) are enqueued explicitly, with the message text frozen at enqueue time:
  ```
  POST /rest/v1/rpc/log_ticket_change
  {"p_ticket_id": "{uuid}", "p_actor": "${GREENHOUSE_TEAM_USERNAME}", "p_action": "updated",
   "p_changes": {"notify": true, "change_note": "{one-liner}"}}
  ```
  Without the `notify` marker an `updated` row is audit-only — incidental edits never notify.
- `tickets.summary` is the body for created/status events; write it via `p_summary` on create and refresh it during tending.

---

## Sync Queue Replay

**Used by:** Every skill as a Step 0, before any other work

Before starting any skill's main logic, check for `.claude/greenhouse-sync-queue.json`. If the file exists and the Greenhouse API is reachable, replay it oldest first. Entries have the shape in [Greenhouse Fallback](#greenhouse-fallback-git-only-mode); a queued write may already have committed (a timeout is not a failure), so every replay is guarded:

1. **Status PATCH** (`expect_status` set) — replay against `{endpoint}&status=eq.{expect_status}` with `Prefer: return=representation`. `[]` (0 rows) means the ticket already moved on — someone or the original request got there first — so drop the entry; never let a stale replay move a ticket backwards.
2. **Comment POST** (`idempotency_key` set) — first check `GET /rest/v1/comments?ticket_id=eq.{ticket_id}&body=like.*gh-sync:{idempotency_key}*&select=id`. A row back means the original POST landed: drop the entry without posting. Otherwise POST the body as queued (it already ends with the `[//]: # (gh-sync:{idempotency_key})` marker).
3. **Anything else** — replay `method`, `endpoint`, `body` as queued, with the standard headers and curl flags.

Then, per entry:

| Replay result | Action |
|---|---|
| 2xx (incl. a guarded 0-row PATCH, or the comment already present) | Remove the entry |
| 4xx — incl. `42501` and any `PGRST*` error | **Drop immediately** and report it: a 4xx won't succeed on retry |
| 5xx / network / timeout | Increment `attempts`. At `attempts >= 3`, drop and report; otherwise keep it |

Write the surviving entries back (delete the file when none remain), then report: *"Replayed {N} queued Greenhouse updates from previous session."* — plus one line per dropped entry: *"Dropped queued {method} {endpoint} ({skill}, {timestamp}): {reason}."* so the user can redo it by hand.

If the file doesn't exist or the Greenhouse API is unreachable, skip silently and proceed (an unreachable API does not count as an attempt).

---

## Greenhouse Fallback (Git-Only Mode)

**Used by:** Any skill when the Greenhouse API is unreachable

When the Greenhouse API is unreachable (network error, timeout, or HTTP 500+):

1. **Continue with git/GitHub operations** — don't block work
2. **Log pending Greenhouse actions** to `.claude/greenhouse-sync-queue.json`:
   ```json
   [
     {
       "action": "update",
       "display_id": "RG-42",
       "endpoint": "/rest/v1/tickets?display_id=eq.RG-42",
       "method": "PATCH",
       "body": {"status": "in_review", "updated_by": "dan"},
       "expect_status": "in_bloom",
       "attempts": 0,
       "timestamp": "2026-02-28T12:00:00Z",
       "skill": "open-pr"
     },
     {
       "action": "comment",
       "display_id": "RG-42",
       "ticket_id": "{uuid}",
       "endpoint": "/rest/v1/comments",
       "method": "POST",
       "body": {"ticket_id": "{uuid}", "author": "dan", "org_id": "{org}", "body": "...\n\n[//]: # (gh-sync:{uuid})"},
       "idempotency_key": "{uuid}",
       "attempts": 0,
       "timestamp": "2026-02-28T12:00:05Z",
       "skill": "merge-pr"
     }
   ]
   ```
   - `attempts` starts at `0`; replay increments it (see [Sync Queue Replay](#sync-queue-replay)).
   - Every status PATCH records `expect_status` — the status the ticket held when you queued it (the one this write replaces).
   - Every comment POST gets an `idempotency_key` (`uuidgen | tr A-Z a-z`) and ends its `body` with a blank line plus `[//]: # (gh-sync:{idempotency_key})`. Generate it **before the first attempt** for any comment you might queue, so a first attempt that timed out but committed is already marked and replay finds it. The marker is a markdown link-reference definition, which renders as nothing — not an HTML comment, which the web app's markdown renderer shows as literal text.
   - Append to existing queue if the file already exists (don't overwrite).
3. **Never block a merge** for Greenhouse unavailability — the git/GitHub side is sufficient
4. **Warn the user** that Greenhouse records are out of sync and will be updated when the API is restored

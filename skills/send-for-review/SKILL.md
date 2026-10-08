---
description: Send a ticket to a teammate for review so it shows as their move on every Greenhouse surface — the plugin side of the web UI's "Send for review" reviewer picker. Meant for no-code work (approvals, copy, decisions) that has no PR to carry the handoff. Use when sending a ticket for review, handing a ticket to someone, asking someone to look at a ticket, or making it someone else's turn.
argument-hint: "{TICKET-ID} [reviewer]"
---

# Skill: Send for Review

Make a ticket someone else's move. This does **one** thing: it sets `tickets.reviewer` with the same table write the web app's Reviewer picker makes. Everything else follows from data Greenhouse already records (GH-91):

- the `ticket_handoffs` view picks up the new pair — `{you} → {reviewer}`, with time in court — on the corkboard tile, the kanban card and the tickets table
- the `log_ticket_changes` trigger writes the activity row, and Slack rules that include **Handed off** post it within about two minutes

**Slack boundary:** this skill never calls Slack, never calls `log_ticket_change`, and never formats a message. The trigger and the dispatch cron do all of that (see [Lifecycle Notifications](../../references/common-operations.md#lifecycle-notifications)).

A ticket with an open PR already has a GitHub-derived pair, and PR stage wins on every surface. Request review on the PR instead. This skill is for work with no PR.

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

**Identity:** the PATCH writes `updated_by = ${GREENHOUSE_TEAM_USERNAME}`, and the trigger records that as the person who handed the ticket off. If `GREENHOUSE_TEAM_USERNAME` is empty, stop with the matching message from [conventions §Current user resolution](../conventions/SKILL.md#current-user-resolution). Never substitute a GitHub login or a Team-table name: the pair would name the wrong person.

---

## Step 1: Resolve the ticket

Resolve Ticket Context from [references/common-operations.md](../../references/common-operations.md#resolve-ticket-context) with the given `{TICKET-ID}`. No ID given → ask for one; don't guess.

The context already carries `id`, `display_id`, `title`, `status`, `assignee` and `reviewer` — don't re-read them. The one field it lacks is `project_id`: take it from the CLAUDE.md `greenhouse` fence when the ticket's key matches `project_key`, and only otherwise read it:

```
GET /rest/v1/tickets?display_id=eq.{ID}&select=project_id
```

Refuse with one line and stop when:

| Status | Reason |
|--------|--------|
| `harvest` | *"{ID} is already harvested — nothing left to review."* |
| `weeded` | *"{ID} was weeded — nothing left to review."* |

---

## Step 2: Resolve the reviewer

The reviewer must be a **Team-table member** (CLAUDE.md) with access to the ticket's project. The value written is their Greenhouse `team_username` — the same string the web picker writes and that `assignee` uses (`"dan"`, `"mb"`) — never a GitHub login.

1. Load the project roster (the same list the web picker offers):

   ```
   POST /rest/v1/rpc/org_avatar_directory
   ```

   Keep the entries whose `project_ids` contains the ticket's `project_id`.

2. Map each Team-table row to its Greenhouse value per [conventions §Team Table](../conventions/SKILL.md#team-table): read the **Greenhouse** column by header name, or bridge a legacy four-column table's `Initials` through `org_avatar_directory.initials`. Keep the rows whose Greenhouse value is a `team_username` in the project roster. Rows with no roster match can't review this project.

3. **Argument given:** match it case-insensitively against the kept rows' Greenhouse and GitHub values. If nothing matches, refuse:

   > *"{arg} isn't a Team-table member with access to {project} — can send to: {names}."*

   **No argument:** choose from the kept rows per [conventions §Reviewer Rule](../conventions/SKILL.md#reviewer-rule), with you (`${GREENHOUSE_TEAM_USERNAME}`) as the implementer. If the rule finds no candidate, there is no one to send to: say so and stop.

4. Stop with one line when:
   - the reviewer is you: *"That's you — pick someone else, or just work it."*
   - the ticket's `reviewer` already equals the target: *"{ID} is already with {reviewer} for review."* (A same-value PATCH changes nothing and logs nothing.)

---

## Step 3: Confirm

This posts to Slack for any rule that includes Handed off. Always confirm, even when the user said to go ahead autonomously:

> *"Send **{ID}** "{title}" to **{reviewer}** for review? It becomes their move on the board, and Slack rules that follow handoffs will post it."*

Proceed only on a yes.

---

## Step 4: Send

```bash
curl -sS -X PATCH "${GREENHOUSE_URL}/rest/v1/tickets?display_id=eq.{ID}" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{\"reviewer\": \"{reviewer_team_username}\", \"updated_by\": \"${GREENHOUSE_TEAM_USERNAME}\"}" \
  | jq '.[0] | {display_id, reviewer, updated_by}'
```

An **empty array** means RLS filtered the write: your token has no access to that project. Say so; don't report success.

Then read the pair back, so the report states what the board now shows rather than what was intended:

```
GET /rest/v1/ticket_handoffs?ticket_id=eq.{uuid}&select=up_next,handed_off_by,handed_off_at,via
```

---

## Step 5: Report

```
{ID} is now in {up_next}'s court ({handed_off_by} → {up_next}, via {via}).
Slack rules that include "Handed off" will post it within ~2 minutes.
To hand it back, clear the reviewer on the ticket (web: Reviewer → "No reviewer (hand back)").
```

If the read-back shows no row, or `via` isn't `reviewer`, someone edited the ticket in between. Report what the view shows instead of the success line.

---

## Error Handling

| Error | Action |
|-------|--------|
| `GREENHOUSE_TEAM_USERNAME` empty | Stop with the conventions message (Step 0) |
| Ticket not found | *"Can't find {ID}."* — stop |
| Reviewer not resolvable | Refuse with the list of who can review (Step 2) |
| PATCH returns `[]` | No access to the ticket's project — say so, no success line |
| Greenhouse API unreachable | Follow [Greenhouse Fallback](../../references/common-operations.md#greenhouse-fallback-git-only-mode): queue the PATCH, tell the user the handoff isn't visible until it replays |

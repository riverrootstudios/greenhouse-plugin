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
GET /rest/v1/brainstorm_notes?project_id=eq.{project_id}&archived=eq.false&select=id,project_id,title,summary,author,tags,dept,source_attribution,customer_id,customers(name),created_at,brainstorm_triage(triaged_by,triaged_at,tickets_touched)&order=created_at.desc&limit=20
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

Fetch the project's open tickets and customers **once per run**, and reuse both lists for every candidate:

```
GET /rest/v1/tickets?project_id=eq.{id}&status=not.in.(harvest,weeded)&select=id,display_id,title,status,type,assignee,summary
GET /rest/v1/customers?project_id=eq.{id}&select=id,name&order=name
```

When the note is Planted, also fetch the tickets its earlier sowings touched (Step 1's `tickets_touched`), whatever their status, and match against them too. A harvested one means the first pass already shipped that ask, so it's **Covered**:

```
GET /rest/v1/tickets?id=in.({tickets_touched})&select=id,display_id,title,status,type,summary
GET /rest/v1/brainstorm_triage?note_id=eq.{note_uuid}&select=triaged_at,dropped
```

The second call reads this note's own earlier drops in full, so a keyword miss can't hide them.

Break the raw dump into a **numbered list of atomic candidate requirements**: one behavior or need per item, deduplicated across sources. A Slack thread and a call transcript often repeat the same ask, so note the repetition, because it signals priority. Digest each candidate as:

```
R{n} {short name}
   Need:      {the job they're trying to get done — not the shape they asked for}
   Quote:     "{their words}" ({speaker}, {timestamp} — when present)
   Today:     {what they do now: a workaround, their old tool, nothing}
   How often: {daily · weekly · monthly · seasonal · once · unknown}
   {marks, when any apply}
```

Marks:

- ***parity***: the ask is framed as the old tool's behaviour ("in {old tool} we can…"). Triage weighs the need underneath, not the old tool's shape.
- ***promised***: someone on our side committed to it on the call ("I will add that"), or widened it ("that'd be good on reports too"). Judge by what is said, because transcript speaker labels are often wrong. A promise doesn't skip the simplicity check.
- ***unsettled***: the discussion didn't land it. It deferred ("we'll circle back", "another meeting", "decide later"), wavered between options without landing, disagreed without resolving, asked a question nobody answered, or left an action with no owner.
- ***partly settled***: the core was decided but a detail was put off.

Judge *unsettled* per candidate from the surrounding exchange, never by matching phrases. Deferral words are mostly filler: "I'm not sure" about a screen share, or "we'll see you soon", is not a deferral.

**Name the note's customer:** the note's `customers.name` when it has one. Otherwise, the customer the feedback is from, matched against the customers list ignoring case, spaces and punctuation ("Yard Guard" is YardGuard), or a new name. A near-match is the existing row, never a second customer. Use none for an internal note such as a team discussion. Step 4 shows it and Step 5 links it.

Show the list to the user before triaging. This list is the coverage guarantee: every item below gets an explicit decision.

---

## Step 2.5: Steer Unsettled Candidates

Skip this step when no candidate is *unsettled*. Otherwise, pause after the list and ask **once, batched**, quoting each unsettled exchange (2–4 lines, with speaker and timestamp when present) and saying exactly what's open:

```
These weren't settled in the discussion:

R4 {short name}
   > {speaker} ({timestamp}): {line}
   > {speaker} ({timestamp}): {line}
   Open: {exactly what was left undecided}
   → Open question{ · or note it in {display_id} — when recommended}

Steer each (e.g. "R4 Open question, R7 note it in {display_id}, R9 settle: {decision}").
Anything not named stays an Open question.
```

| Steer | What happens |
|-------|--------------|
| **Open question** (default) | No ticket. Step 6 records an **Open question** drop on the note, carrying the question |
| **Note it in a no_code ticket** | Append the open point to an existing decision ticket's `open_decisions`, or create a `no_code` "Decide …" ticket. Recommend this only when a `no_code` ticket on the topic is already in the open-ticket list, or when the discussion named who decides. Read that ticket's context first: when its `open_decisions` already hold the point, the Open question drop names it instead of duplicating it |
| **Settle it now** | The user states the decision, and the candidate triages normally with it. When a ticket or an earlier drop has decided the point since the discussion, recommend this and quote that decision |
| **It's settled** | Claude misread the exchange, and the candidate triages normally |

**An unsettled candidate never becomes a code ticket** unless the user settled it in this conversation.

Given every candidate is unsettled, say the discussion hasn't landed yet. Offer to record nothing (the note stays Raw, or Planted on a re-sow), or to record only the Open question drops.

A *partly settled* candidate isn't steered. Its settled part triages normally, and the deferred detail goes in that ticket's `open_decisions` (Step 5), so tend asks about it first.

---

## Step 3: Triage Each Requirement

### Earlier drops

Once per run, right after the Step 2 list (so Step 2.5 can use it), fetch the project's sowings and keep only the drops that bear on this note. The download is the whole history; only the matches reach the context:

```bash
: > /tmp/gh-drops.ndjson; off=0
while :; do
  page=$(curl -sSf --connect-timeout 5 --max-time 30 --retry 2 \
    "${GREENHOUSE_URL}/rest/v1/brainstorm_triage?select=triaged_at,dropped,brainstorm_notes!inner(title,customer_id,customers(name))&brainstorm_notes.project_id=eq.{project_id}&order=triaged_at.desc,id.asc&limit=250&offset=${off}" \
    -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}") \
    || { echo "earlier-drops fetch failed at offset ${off}" >&2; break; }
  printf '%s' "$page" | jq -c '.[]' >> /tmp/gh-drops.ndjson
  [ "$(printf '%s' "$page" | jq length)" -lt 250 ] && break
  off=$((off + 250))
done
jq -s . /tmp/gh-drops.ndjson > /tmp/gh-drops.json

jq -r --arg re '{keywords}' '
  .[] | . as $t | .dropped[]
  | select(((.requirement + " " + .reason) | test($re; "i")) or (.reason | test("^Decided"; "i")))
  | "\($t.triaged_at[:10]) · \($t.brainstorm_notes.title // "untitled") · \($t.brainstorm_notes.customers.name // "—") · \(.requirement) → \(.reason)"
' /tmp/gh-drops.json | sort
```

Write `{keywords}` from the whole candidate list as one alternation. Use 2–4 distinctive terms per candidate, covering the nouns, their synonyms and the old tool's name for the thing (`commercial|residential|class code|customer type`). Leave out words every note uses (`customer`, `invoice`), and wrap short stems in `\b` so `\btended\b` doesn't match "intended". It's a regex, so escape `$` and `.`. Show the user only the lines that bear on a candidate; a keyword hit on an unrelated drop is left out. If the output passes ~60 lines, tighten the keywords and re-run jq on the saved file; never re-fetch. Every **Decided** drop is printed too, because they are the project's standing rules.

When the note's customer is an existing row, list that customer's earlier **Open question** drops from the same file, so the sower can see whether this transcript answered them. This is display only: nothing tracks a question as open or closed.

```bash
jq -r --arg cid '{customer_uuid}' '
  .[] | select(.brainstorm_notes.customer_id == $cid) | . as $t | .dropped[]
  | select(.reason | test("^Open question"; "i"))
  | "\($t.triaged_at[:10]) · \($t.brainstorm_notes.title // "untitled") · \(.requirement) → \(.reason)"
' /tmp/gh-drops.json | sort
```

When neither command prints anything, show nothing extra and ask nothing. Older drops have no reason prefix, but the keyword match finds them anyway.

### For each candidate

Run the four checks in order:

1. **Exists check:** match the candidate against the open-ticket list and the earlier drops, with no new query per candidate. For any matched ticket, pull its context, including comments, with `POST /rest/v1/rpc/get_ticket_context`. Comments are notes, not a workflow state: read them so the triage decision accounts for what's already been discussed. A matching drop is an earlier decision. Follow a **Decided** drop as a rule unless the user overrides it, and say which one applies. When a candidate reports broken something a **Covered** drop said works, it's a regression.
2. **Accept or modify:** present the requirement as digested. The user accepts it as-is or refines the wording or scope.
3. **Simplicity check:** place the candidate on the [Simplicity Ladder](../../references/work-breakdown.md#simplicity-ladder). Name its rung (a ticket's rung is its highest part, so name that part), the cheapest lower rung that might do, and why it doesn't. A *promised* or *parity* candidate goes through this like any other: the promise is to meet the need, not to copy the shape. **A regression or bug is its own ticket**, never an item inside a feature ticket.
4. **Decision:** one of:
   - **Create** a new ticket for code work that ends in a PR
   - **Create (no_code)** for a design, copy, research, or decision follow-up with no PR, using the existing `no_code` type. Never ask for or invent a complexity score for these
   - **Update** an existing ticket (append acceptance criteria)
   - **Drop**, with a reason that starts with one of the drop words below (recorded, revisitable)

### Drop reasons

Every drop reason starts with one of these words, then a colon and the specifics: `Covered: statements give any date range (ROOTS-400)`.

| Word | When |
|------|------|
| **Covered** | An existing feature or ticket meets it. Cite it |
| **Answer** | A question answered, with nothing to build |
| **Decided** | A standing product rule. Cite the ticket that made it. Later sowings read these as rules |
| **Process** | An ops or people action, not product |
| **Not now** | Worth doing, not yet |
| **One asker** | One customer's need that doesn't hold for others |
| **Not product** | Outside what the product does |
| **Concern** | A worry with no ask |
| **Open question** | The question rides along. This is the default for anything the discussion left unsettled |

When a Create overrides an earlier drop's reason (the drop said "flags cover it", and now the column is being built), the CREATE line in Step 4 says so. The batch then carries a **Decided** drop naming the new ticket, so later sowings don't follow the old reason. Step 6 records it once the ticket has its ID.

---

## Step 4: Confirm the Batch

Present the full plan before writing anything:

```
Customer: {name} (linked) | {name} (new — will be added and linked) | none (internal note)

About to:
  • CREATE  — "{title}" [{type}] · rung {n}: {what} — cheaper: {alternative}, not enough because {why}
              {· promised}{ · earlier asks: {dates}}{ · overrides {date} drop "{reason}"}{ · open_decisions: {deferred detail}}
  • CREATE  — "{title}" [no_code]{ · blocks {titles or display_ids}}
  • UPDATE {display_id} — add AC: {one-liner}
  • UPDATE {display_id} — open_decisions: {the unsettled point}{ · blocks {...}}
  • DROP   R{n} — {requirement} ({Word}: {reason})
Proceed?
```

The rung, the cheaper alternative and the customer link are approved in this same confirm. They add no new question. Wait for approval. Iterate on feedback.

---

## Step 5: Execute

**Creates** — `POST /rest/v1/rpc/create_ticket` following the field conventions in [skills/create-ticket](../create-ticket/SKILL.md) Step 6. Always include **`p_summary`** (one/two-sentence, non-technical "what this delivers") — it is the Slack message body for this ticket's lifecycle events. For a **no_code** row, send `p_type: "no_code"` and omit `p_complexity` entirely.

The description **starts** with these lines, each its own paragraph, so the origin and the argument for the ticket survive into it. Write each line only when its condition holds:

```
**Source:** {source_attribution}

**Rung:** {n} · {what} — cheaper: {alternative}, not enough because {why}

**Promised:** {who} on "{note title}": "{quote}"

**Earlier asks:** {date} {note title}{, customer}; {date} {note title}{, customer}{ — overrides "{reason}"}

{rest of the description}
```

| Line | When |
|------|------|
| **Source** | The note carries `source_attribution` (GH-67) |
| **Rung** | Code creates only, never `no_code` |
| **Promised** | The candidate is *promised* |
| **Earlier asks** | The earlier-drops check matched this candidate |

A *partly settled* create gets the deferred detail in `open_decisions`. `create_ticket` has no parameter for it, so PATCH it right after the create with the `--rawfile` pattern.

**Updates** — for each existing ticket:

1. PATCH the ticket: append to `acceptance_criteria` (use the temp-file + `--rawfile` pattern from [common-operations §Posting Comments](../../references/common-operations.md#posting-comments-and-patching-multi-line-ticket-fields)), and set `change_note` to a one-liner: `via brainstorm '{note title/excerpt}': {what changed}`. Include `updated_by`: `${GREENHOUSE_TEAM_USERNAME}`.
2. Enqueue the notification — the note text is frozen at enqueue time by design:
   ```
   POST /rest/v1/rpc/log_ticket_change
   {"p_ticket_id": "{uuid}", "p_actor": "${GREENHOUSE_TEAM_USERNAME}", "p_action": "updated",
    "p_changes": {"notify": true, "change_note": "via brainstorm '{...}': {what changed}"}}
   ```
   The `notify` marker is what makes the row deliverable — a plain PATCH never notifies.

**Decision tickets** — for each candidate the user steered into a no_code ticket in Step 2.5:

1. Create the `no_code` "Decide …" ticket like any other create. For an existing one, append the open point to its `open_decisions` as an Update: the same PATCH, `change_note` and notification as above, with `open_decisions` in place of `acceptance_criteria`.
2. Add a `blocks` relation from the decision ticket to each build ticket that depends on it, whether created in this run or already open (`POST /rest/v1/ticket_relations` with `source_ticket_id` = the decision ticket, as in [status-flows §Blocks](../../references/status-flows.md#blocks--blocked-by-relations-table)). Skip a pair that is already related.

**Customer** — when Step 4 named a customer and the note isn't linked to it yet:

1. A new name: `POST /rest/v1/customers` with `{"project_id": "{project_id}", "name": "{name}", "org_id": "${GREENHOUSE_ORG_ID}", "created_by": "${GREENHOUSE_TEAM_USERNAME}"}` and `Prefer: return=representation`. A `23505` means the name already exists in another case, so GET it with `GET /rest/v1/customers?project_id=eq.{project_id}&name=ilike.{name}&select=id,name` and use that row.
2. `PATCH /rest/v1/brainstorm_notes?id=eq.{note_uuid}` with `{"customer_id": "{customer_uuid}"}`.

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
 "dropped": [{"requirement": "{text}", "reason": "{Word}: {why}"}, ...],
 "action_summary": "{N} created, {M} updated, {K} dropped"}
```

On a re-sow, a candidate this note's earlier sowing already dropped for the same reason isn't recorded again. `dropped` carries every Drop, every **Open question** from Step 2.5, and any **Decided** override from Step 3, which names the ticket created in Step 5. Each reason starts with a [drop word](#drop-reasons).

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
| 4 | {req}       | dropped — {Word}: {reason} | — |

{Customer: {name} linked — only when Step 5 linked one.}
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
| Earlier-drops fetch fails | Say so and triage against the open tickets only; the Step 4 plan notes that earlier drops weren't checked |
| `create_ticket` / PATCH fails | Queue to `.claude/greenhouse-sync-queue.json` per Greenhouse Fallback; report which writes landed |
| `log_ticket_change` fails after PATCH succeeded | Ticket is updated but won't notify — retry once, then note it in the summary (content is source of truth; the Slack line is best-effort) |
| User rejects the whole batch | Record nothing; the note stays Raw (or Planted, on a re-sow) |

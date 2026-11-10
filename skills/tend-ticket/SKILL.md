---
description: Make a ticket implementation-ready by tending it collaboratively — surfacing acceptance criteria as they form, refining scope/architecture/infra decisions with the user, and eliciting requirements they hadn't thought to state. Adds test cases and identifies files. Use when tending tickets, preparing for AI implementation, or expanding acceptance criteria.
argument-hint: "[ticket-id]"
---

# Skill: Tend Ticket

The most important skill for autonomous workflow — a well-tended ticket means Claude Code can implement with no additional human input. Tending is a **conversation, not a form-fill**: its real job is to pull out the requirements, decisions, and constraints the user hasn't thought to say yet.

---

## Working Mode

**Collaborative by default.** Tend *with* the user — surface the acceptance criteria as they take shape (not just a finished block at the end), and pause at real decision points instead of guessing. The goal is to end with a ticket that captures intent the user hadn't articulated at the start.

**Proportional to complexity.** Don't interrogate a 1–2pt ticket — a quick confirm is enough. Scale the questioning up with the score: 8pt+ tickets deserve genuine back-and-forth on scope, architecture, and infrastructure; 16pt+ almost always hide unstated requirements worth surfacing before any code is written.

**One-shot escape hatch.** If the user says "just tend it" / "don't ask" / "autonomous," skip the interactive prompts, make reasonable choices, record assumptions in `open_decisions`, and present the result in one pass. The [Premise Check](#step-23-premise-check) still runs: take its recommended outcome and record it in `open_decisions`.

Route surfaced decisions into the ticket: firm choices become acceptance criteria; unresolved ones go to `open_decisions` so `work-ticket` inherits them.

When a tending session pauses mid-way (a long ticket, a decision the user needs to go check on), hand off using [references/checkpoint-handoff.md](../../references/checkpoint-handoff.md) — same format `work-ticket` uses between phases, so a pause reads the same wherever it happens: what's settled so far, what you should be aware of, what's still open, and the next ask.

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

- Load [references/greenhouse-schema.md](../../references/greenhouse-schema.md) for ticket field reference

---

## Step 1: Resolve Ticket

**If ticket ID provided:**
- Resolve via Resolve Ticket Context in [references/common-operations.md](../../references/common-operations.md)

**If no ticket ID:**
- Auto-pick untended: `GET /rest/v1/tickets?project_id=eq.{id}&tended=is.false&status=in.(sprouted,seeds)&order=priority.asc,created_at.asc&limit=1&select=display_id,title,status,priority`
- Confirm with user: *"Next untended ticket is {display_id}: {title}. Tend this one?"*
- Then resolve full context via common-operations

**If not found:** *"No untended tickets in sprouted or seeds — want me to plan some new work?"*

**Waiting on a decision:** check this before anything else. When the context's relations hold a `blocked_by` entry whose `related_status` isn't `harvest` or `weeded`, look up those tickets' types (`GET /rest/v1/tickets?id=in.({related_ticket_ids})&select=display_id,title,type`). If one is `no_code`, say so first and recommend waiting for that decision:

> "{ID} is blocked by {decision ID}: {title}, a decision that hasn't been made. Tending now builds on a guess, so I'd wait for it. Tend anyway?"

Continue only on the user's say-so. A one-shot tend notes the wait in `open_decisions` and continues, since work-ticket's blocker check holds the work back anyway.

**Show that it's being tended:** once the ticket is settled, label this chat with it, so the ticket's tile shows the tend pill wherever gh-dash runs (GH-133):

```bash
${CLAUDE_PLUGIN_ROOT}/bin/gh-coord working {TICKET-ID} tend 2>/dev/null || true
```

It's a label, not a claim: it never stops another chat from working the ticket, and without gh-dash nothing shows. Clear it on every way out (Step 7, a park or weed, or the user stopping the tend): `${CLAUDE_PLUGIN_ROOT}/bin/gh-coord working - 2>/dev/null || true`.

---

## Step 2: Read Codebase Context

Based on the ticket's description and labels:

1. Identify the relevant area of the codebase
2. Read key files: architecture, patterns, related components
3. Check for existing similar implementations to follow as patterns
4. Note any recent changes that might affect this ticket

---

## Step 2.3: Premise Check

Asks whether a big ticket that came from feedback should be built as scoped, before its criteria are expanded. Run it only when both of these hold, and otherwise skip it without saying anything:

- **Sown:** a sowing touched this ticket. `%7B…%7D` is the array's braces, URL-encoded:
  ```
  GET /rest/v1/brainstorm_triage?tickets_touched=cs.%7B{ticket_uuid}%7D&select=triaged_at,brainstorm_notes(id,title,customer_id,customers(name))
  ```
  An empty array means the ticket isn't sown. The description's `**Source:**` line is no signal, because sow writes it only when the note has `source_attribution`.
- **Big:** `complexity` is 16 or more, or Step 2's reading puts it there (a first tend still carries sow's rough score), or it sits on rung 5: a `**Rung:** 5` line, or a core-model column or table, nav item, org setting or service line in its scope.

Build the case from the ticket and these sources:

- **Need:** what the asker is trying to get done. Take it from the sowing notes, reading only the exchange the ticket came from: save each note's body to a temp file (`GET /rest/v1/brainstorm_notes?id=eq.{note_id}&select=body`) and `grep -n -i -E -C10 '{keywords}'` it, never reading the whole transcript.
- **Who asked:** those notes (title, customer, date), plus the earlier drops that match. Run [sow-feedback §Earlier drops](../sow-feedback/SKILL.md#earlier-drops) with keywords from this ticket.
- **Rung:** the `**Rung:**` line, or place it on the [Simplicity Ladder](../../references/work-breakdown.md#simplicity-ladder) now. A ticket's rung is its highest part, so name that part.
- **Cheaper:** the lowest rung that might meet the need, and why it doesn't.
- **Not building costs:** what the asker keeps doing if this never ships.

End in one decision, asked as one question rather than a series:

```
Premise: {ID} — {title} ({N}pt, rung {n})
Need:       {…}
Who asked:  {date} {note title}, {customer}; earlier: {date} {note title} — {reason}; …
Rung:       {n} · {the part that sets it}
Cheaper:    {alternative} — not enough because {why}
Not building costs: {…}

Decision: build {ID} as scoped
Options: proceed / shrink / park / weed
Recommend: {one} — {one-line why}
```

| Outcome | What happens |
|---------|--------------|
| **proceed** | Continue to Step 2.5 |
| **shrink** | Rewrite the scope in this tend, so the criteria and description follow the smaller version, and continue. A cut part that still needs doing, such as a bundled regression, goes on the [out-of-scope list](../../references/common-operations.md#out-of-scope-findings) and is filed only on a yes |
| **park** | PATCH `status` → `seeds` without setting `tended`, and comment the Open question that has to be answered first. Stop the tend |
| **weed** | PATCH `status` → `weeded`, and comment the reason. Stop the tend |

Park and weed PATCHes carry `updated_by`, and their comments carry `author` and `org_id`, all as in Step 7.

---

## Step 2.5: Architectural Risk Scan

If the ticket touches navigation, client state, new database tables, new dependencies, or introduces a pattern not already in the codebase, load [references/engineering-conventions.md](../../references/engineering-conventions.md) and evaluate against it.

Surface findings **only when risks are present** — skip this section entirely if nothing is flagged:

```
⚠ Risk: {name}
Why it matters: {brief explanation}
Better path: {recommendation}
Ask: {1–2 followup questions}
```

---

## Step 2.7: Elicit Requirements (Socratic)

Before expanding criteria, draw out what the ticket *doesn't* say yet. Ask targeted questions — batch a focused handful, don't drip one at a time — aimed at the gaps most likely to bite. Skip questions the ticket or codebase already answers; only ask what genuinely changes the work.

**Start with any `open_decisions` already on the ticket,** such as a detail sow deferred, and put them before the lenses. Then run through these lenses, as relevant:

- **Themes & fit** — what's the underlying theme, and how does this fit the product and existing patterns? Is it consistent with how the rest of the app already works, or introducing a new way of doing something?
- **Simplicity** — state a position the user can refute, not an open question: *"a flag does this at 4pt; the column buys X — keep it only if X matters."* Draw on one or two of these questions, never all of them:
  - What do they do if we never build it?
  - Would the smallest and the largest customer use it the same way?
  - Is it a new thing to learn, or an existing thing getting better?
  - What do we hide to make room?
  - What does the customer stop doing once it ships?

  The [Simplicity Ladder](../../references/work-breakdown.md#simplicity-ladder) names the cheaper rungs. Push back on accidental complexity.
- **UX completeness** — every state and path: empty, loading, error, partial, concurrent, offline, first-run, at-limit; plus success/confirmation, undo, and mobile/responsive and accessibility.
- **Data model updates** — new/changed tables or columns, relationships, constraints, indexes, migrations and backfill, and RLS implications of the shape.
- **Auth patterns** — who can do this? Role/permission checks, org/tenant scoping, RLS policies, and whether it follows the existing auth model or bends it.
- **Decisions the user may not know they're making** — new dependency vs build-it, an external service, sync vs async, a new pattern vs an established one.
- **Non-functional needs** — performance/scale, security/privacy, observability.
- **Done, precisely** — how will we know it works? What must a reviewer be able to verify?

Present each material decision with a recommended default so the user can confirm fast:

```
Decision: {the choice}
Options: {A} / {B}
Recommend: {A} — {one-line why}
```

Feed the answers into Step 3. Firm answers → acceptance criteria; open questions → `open_decisions`. For a one-shot tend (see Working Mode), skip the prompts, choose the recommended defaults, and list them under `open_decisions` as assumptions.

---

## Step 3: Expand Acceptance Criteria

Transform vague criteria into specific, testable, implementable items, folding in the answers from Step 2.7. **Surface the criteria to the user as you build them** — show the working list and let them react before you finalize; don't reveal a finished block only at Step 6. For each criterion:

### Behavior Specifications (Given/When/Then)

```
- [ ] Given {precondition}, when {action}, then {expected outcome}
- [ ] Given {edge case}, when {action}, then {error handling}
```

### Edge Cases & Error Handling

- What happens when input is empty/null/invalid?
- What happens on network failure?
- What happens at boundary values?
- What's the error message the user sees?

### Test Cases

Per RIVERROOT testing philosophy (see [references/riverroot.md](../../references/riverroot.md)), list test cases with descriptive names:
```
- [ ] Test: "returns 403 when user is not a member of the tenant"
- [ ] Test: "creates subscription with trial period when plan includes trial"
```

### Files & Modules

List specific file paths that will be created or modified:
```
- [ ] Create: app/(dashboard)/settings/password/page.tsx
- [ ] Create: app/api/auth/reset-password/route.ts
- [ ] Modify: lib/auth/actions.ts — add resetPassword server action
- [ ] Create: __tests__/auth/reset-password.test.ts
```

### Database Changes

If applicable:
```
- [ ] Migration: add `password_reset_tokens` table
- [ ] RLS: enable RLS, add policy for token owner only
- [ ] Trigger: auto-expire tokens after 1 hour
```

### API Contract Changes

If applicable:
```
- [ ] POST /api/auth/reset-password — accepts { email }, returns 200 (always, for security)
- [ ] POST /api/auth/reset-password/confirm — accepts { token, newPassword }, returns 200 or 400
```

---

## Step 3.5: Review Labels

Enrich labels based on the expanded acceptance criteria and files identified above (see conventions Labeling Philosophy). Aim for 2-5 labels.

Leave epic linkage alone — epics are opt-in ([conventions §Epic Usage](../conventions/SKILL.md#epic-usage)). Don't look one up or suggest one.

---

## Step 4: Score Complexity

With the codebase context from Step 2 and the expanded scope from Step 3, score the ticket's complexity. This is free — you've already read the relevant files.

Using the assessment fields and complexity scale from [references/work-breakdown.md](../../references/work-breakdown.md):

1. **Assess** — file scope, change type, blast radius, reversibility, testing needs, established pattern, confidence
2. **Score** — map to 1-64 using the complexity scale
3. **Summarize** in compact format: `{N}pt {approach} · {file scope} · {change type} change · {blast radius} risk · {reversibility} · {testing} · {established pattern}`
4. **Check decomposition** — 64pt is large; ask the user if they'd like to split, but don't require it. 32+ needs self-review checkpoints

If complexity increased significantly from the rough score set by `create-ticket`, flag it.

> "After tending, this ticket scores {N}pt ({approach}). {If 64pt: 'This is a large ticket — would you like to split it, or proceed as one PR?' If 32+: 'Self-review checkpoints recommended between phases.'}"

---

## Step 5: Identify Blockers

Check whether this ticket depends on work in other tickets:
- Database migrations created by another ticket?
- API routes from another ticket?
- Components from another ticket?

If blockers found:
1. `POST /rest/v1/rpc/resolve_display_ids` with `{"p_display_ids": ["{blocker-ID1}", "{blocker-ID2}"]}` to get UUIDs
2. `POST /rest/v1/ticket_relations` for each: `{"source_ticket_id": "{blocker-uuid}", "target_ticket_id": "{this-ticket-uuid}", "relation_type": "blocks", "created_by": "${GREENHOUSE_TEAM_USERNAME}", "org_id": "${GREENHOUSE_ORG_ID}"}` — `org_id` is required by RLS; use `${GREENHOUSE_ORG_ID}` from the `gh-jwt` eval (see [common-operations §org_id on writes](../../references/common-operations.md#org_id-on-writes)).
3. Run the Blocker Check from [references/common-operations.md](../../references/common-operations.md)

---

## Step 6: Present Expanded Ticket

Show the complete expanded ticket for confirmation:

```
## {TICKET-ID}: {title}

**Type:** {type} | **Priority:** {priority} | **Complexity:** {N}pt {approach}
**Assignee:** {assignee} | **Reviewer:** {reviewer}
**Labels:** {labels}

### Acceptance Criteria (Expanded)

- [ ] {criterion 1 — specific, testable}
- [ ] {criterion 2}
...

### Test Plan

- {test 1}
- {test 2}
...

### Files

- Create: {path}
- Modify: {path}

### Blocked By

- {TICKET-ID}: {reason}
```

Iterate until approved.

---

## Step 7: Update Greenhouse

On approval:

1. `PATCH /rest/v1/tickets?display_id=eq.{ID}` — update the ticket:
   - `acceptance_criteria`: expanded version
   - `labels`: enriched with 2-5 labels based on implementation scope
   - `epic_id`: only when the user set one in this tending conversation
   - `complexity`: scored value (1-64)
   - `open_decisions`: any unresolved questions surfaced during tending
   - `summary`: refresh the one/two-sentence plain-English "what this delivers" if tending changed the scope (it's the Slack notification body — keep it non-technical)
   - `tended`: `true`
   - `updated_by`: `${GREENHOUSE_TEAM_USERNAME}`
   - Write the Complexity Assessment section to the description (see [templates/ticket-body.md](../../templates/ticket-body.md))

2. If status was `seeds` → include `status`: `sprouted` in the same PATCH

3. `POST /rest/v1/comments` (`author`: `${GREENHOUSE_TEAM_USERNAME}`; include `org_id` from `${GREENHOUSE_ORG_ID}` — RLS rejects the insert without it) — body is `"Tended by Claude Code. Expanded {N} acceptance criteria, added {M} test cases, identified {K} files to modify. Complexity: {N}pt {approach}. Ready for implementation."` plus any audit-finding notes. Use the temp-file + `--rawfile` pattern in [references/common-operations.md](../../references/common-operations.md) §Posting Comments and PATCHing Multi-line Ticket Fields — do NOT inline `--arg body "..."` because acceptance criteria and tending notes contain newlines.

The same pattern applies to the PATCH in step 1 — `acceptance_criteria` and `description` are multi-line, so each goes through `--rawfile` against its own temp file.

4. Clear the tend label from Step 1: `${CLAUDE_PLUGIN_ROOT}/bin/gh-coord working - 2>/dev/null || true`.

---

## Quality Checklist

Before marking as tended, verify every acceptance criterion:

- [ ] Is specific (no vague words like "properly", "correctly", "handle")
- [ ] Is testable (can write a test that passes/fails based on this)
- [ ] Is independent (doesn't rely on the implementer "knowing" something)
- [ ] Includes the expected behavior AND the error case
- [ ] References specific files, routes, or database tables where applicable

A well-tended ticket should be implementable by someone who has never seen the codebase — they just need the acceptance criteria, the file paths, and RIVERROOT conventions.

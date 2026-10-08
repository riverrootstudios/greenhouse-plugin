---
description: Address PR review comments autonomously. Reads feedback, implements fixes, re-requests review. Use when fixing review comments, addressing feedback, or handling review.
argument-hint: "[ticket-id]"
---

# Skill: Fix Review Feedback

Autonomously address PR review comments: parse structured `[REQUIRED]`/`[NOTED]` findings, implement all required fixes, re-request review. Designed to consume the structured output from `review-pr` without interpretation.

**Fix only what the review raised.** Adjacent issues you notice along the way — a nearby bug, a stale comment, a refactor the fix invites — go into the out-of-scope findings list ([common-operations §Out-of-Scope Findings](../../references/common-operations.md#out-of-scope-findings)), shown in the Step 9 summary. They are not fixed in this round and no ticket is filed without a yes.

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

## Step 1: Resolve Ticket & PR

**If ticket ID provided:**
- If you already hold this ticket's context from the calling skill (e.g. a project-specific wrapper skill that resolved it first), reuse it; otherwise resolve via Resolve Ticket Context in [references/common-operations.md](../../references/common-operations.md) — extract `pr_url` from response
- Get PR number from the ticket's `pr_url`

**If no ticket ID:**
- Auto-pick: `GET /rest/v1/tickets?project_id=eq.{id}&status=eq.changes_requested&select=display_id,title,pr_url&order=created_at.asc&limit=5`
- If multiple → pick the oldest, or ask user
- If none → *"No tickets with changes requested. Nothing to fix."*

Get the PR number from the ticket's `pr_url`.

**Gate — PR State:** Run the [PR State Guard](../../references/common-operations.md#pr-state-guard) before reading feedback or writing any code. Feedback on a closed or merged PR is already resolved or abandoned — implementing it re-opens settled work and pushes commits to a branch nobody is going to merge.

---

## Step 2: Read Review Feedback

### GitHub Review Comments
```bash
gh pr view {number} --json reviews,comments,reviewRequests
gh api repos/{owner}/{repo}/pulls/{number}/comments
```

Collect:
- Review comments (inline on specific lines)
- General review comments
- Conversation threads
- Review verdict (changes requested, comments only)

### Greenhouse Comments
The ticket context already carries the latest 5 comments (`get_ticket_context` returns them) — read those for additional feedback. Fetch more only when all 5 postdate the review being addressed and older ones may matter:

`GET /rest/v1/comments?ticket_id=eq.{uuid}&select=author,body,created_at&order=created_at.desc&offset=5&limit=10`

---

## Step 3: Parse Findings

- **Structured** (`[REQUIRED]`/`[NOTED]` tags from review-pr): Implement `[REQUIRED]` fixes directly using the `Fix:` instruction. Skip `[NOTED]`.
- **Unstructured** (human prose): Ask user to classify each comment as `[REQUIRED]` or skip before implementing.
- **Mixed:** Handle structured directly, escalate unstructured to user.

---

## Step 4: Check Out Branch

```bash
git checkout {branch-name}
git pull origin {branch-name}
```

If the branch is behind `{base}` ([Resolve Base Branch](../../references/common-operations.md#resolve-base-branch) — the open PR's `baseRefName` wins here), run [Inline Rebase](../../references/common-operations.md#inline-rebase).

---

## Step 5: Implement Fixes

For each `[REQUIRED]` finding:

1. **Read the `Fix:` instruction** — this is the change order. Implement it directly.
2. **Read surrounding context** — verify the fix makes sense in context before applying
3. **Make the change** — follow RIVERROOT conventions
4. **Add/modify tests** if the fix changes behavior
5. **Reply on GitHub** — confirm what was changed:
   ```bash
   gh api repos/{owner}/{repo}/pulls/{number}/comments/{comment-id}/replies \
     -f body="Fixed — {brief description of change}"
   ```

For `[NOTED]` items: skip entirely. No reply, no action.

For unstructured comments classified by the user in Step 3b: implement as directed by the user's classification.

---

## Step 6: Run Quality Gate

Run the quality gate (see conventions). Fix any new failures introduced by the changes.

---

## Step 7: Push & Re-Request Review

Stage changed files by name (prefer specific files over `git add -A`):

```bash
git add {file1} {file2} ...
git commit -m "fix: address review feedback [{ticket-id}]"
git push origin {branch-name}
```

Re-request review from **whoever submitted the review being addressed** — the `author.login` on that review from Step 2. That's a fact, not a choice: ask nothing, and name them in the output. (Handing the review to someone else is a separate action, GH-104.) Do NOT dismiss the old review — dismissals error on many repo configurations and are not the right flow. The reviewer submits a fresh review on the updated code.

Use the REST API, never `gh pr edit --add-reviewer` — in this org that command fails silently (a Projects-classic GraphQL error comes back as success), so the re-request never lands:

```bash
gh api -X POST repos/{owner}/{repo}/pulls/{number}/requested_reviewers \
  -f "reviewers[]={GitHub login of the review you addressed}" --silent
```

Then read it back:

```bash
gh api repos/{owner}/{repo}/pulls/{number}/requested_reviewers --jq '[.users[].login]'
```

If `{reviewer-login}` isn't in the list, say so in the summary — *"Re-request to @{reviewer-login} didn't land ({error or empty list}); request it from the PR page."* — never report it as done.

Leave a comment so the reviewer knows what changed:
```bash
gh pr comment {number} --body "Review feedback addressed — {N} required changes fixed. Ready for re-review."
```

---

## Step 8: Update Greenhouse

Single `PATCH /rest/v1/tickets?display_id=eq.{ID}&status=neq.in_review` on the ticket — the filter guard means a re-run (status already `in_review`) matches 0 rows and writes nothing, so it fires no realtime refetch. Skip the call outright when the status you fetched is already `in_review`:
- `status` → `in_review` (back from `changes_requested`)
- `updated_by` → `${GREENHOUSE_TEAM_USERNAME}`

`POST /rest/v1/comments` (`author`: `${GREENHOUSE_TEAM_USERNAME}`; include `org_id` from `${GREENHOUSE_ORG_ID}` — RLS rejects the insert without it) — body summarises the round: "Review feedback addressed. {N} comments resolved:" followed by a bulleted list of fixes, any questions replied to, which reviewer was re-requested (and whether the read-back confirmed it), and the out-of-scope findings list when it isn't empty. The body is multi-line — construct it using the temp-file + `--rawfile` pattern in [references/common-operations.md](../../references/common-operations.md) §Posting Comments and PATCHing Multi-line Ticket Fields.

If the Greenhouse update fails with a 5xx or network error (`--retry 2` has already retried it; never retry a 4xx), log to sync queue with `expect_status: "changes_requested"` (see [references/common-operations.md](../../references/common-operations.md) Greenhouse Fallback). Warn the user explicitly — never silently skip status updates.

---

## Step 8.5: Capture Pattern (opt-in)

This step is **opt-in, not default-on**. Pattern capture is valuable but interruptive — the user often wants to stop after the fix lands and pick this up later, if at all.

Begin by listing capture candidates and asking once:

> "Fixes are pushed. {N} `[REQUIRED]` findings are candidates for this repo's `.claude/review-patterns.md`:
> - {finding title 1}
> - {finding title 2}
>
> Walk capture for all, pick which to capture, or skip?"

Default on no reply or ambiguous reply: **skip**. Proceed to Step 9. Do not run capture without an explicit go-ahead in this exchange.

Acceptable go-aheads: `walk all`, `capture`, `do it`, naming specific findings, or `yes`. Anything else (silence, `not now`, `skip`, `later`) → skip and continue.

For each finding the user opted in for:

1. Ask: "Could a pre-PR checklist item have prevented this?" If no → skip
2. Check both layers for an existing entry that covers this pattern: [references/review-patterns.md](../../references/review-patterns.md) (the plugin's shared baseline) and the current repo's `.claude/review-patterns.md`
3. If no existing entry covers it, append a new pattern entry to the **current repo's** `.claude/review-patterns.md` — never to the plugin copy, which outside the greenhouse repo is the installed plugin cache (edits there are never committed and vanish on refresh). On first capture, create the file with the plugin file's header line and entry template (the commented block under `## Patterns`), then append:

```markdown
### {Pattern Name}
- **First seen:** PR #{number}, {TICKET-ID}
- **Severity:** REQUIRED
- **Category:** Bug/Logic | Style/Convention | Architecture | Missing Test | Over-generation | Cohesion
- **What happened:** {brief description of the review feedback}
- **Prevention rule:** {concrete check the self-review should perform}
```

4. Update the `Last updated` date in that file's header. The new file shows up in `git status` and ships with the fix commit like any other change

Skip one-off issues that are unlikely to recur (typos, variable name preferences, context-specific decisions).

---

## Step 9: Summary

Output to user. Be explicit about what actually landed vs what is held — never leave the state of a fix ambiguous:

```
## Review Feedback Addressed — {TICKET-ID}

### Committed & Pushed
- {fix 1}: {description} ({file:line})
- {fix 2}: {description}

### Held (not committed) — needs your input
- {finding}: {why it's held — e.g. "escalated: changes architecture", "couldn't reproduce", "conflicts with {other requirement}"}
- (or "None — everything is committed and pushed.")

### Replies Posted
- {comment}: {reply summary}

### Out of Scope — Not Filed
{the findings list, when not empty, ending: Say "file 2" and I'll create a ticket for it.}

### Quality Gate
All passing

PR #{number} updated{, review re-requested from {reviewer} (confirmed) | , re-request to {reviewer} did NOT land — request it from the PR page | — review NOT re-requested because items above are held}.
```

If anything is in the **Held** list, do not re-request review until the user resolves it — say so plainly rather than implying the round is complete.

---

## Error Handling

| Error | Action |
|-------|--------|
| PR not found | Check ticket's `pr_url`, search GitHub |
| Branch deleted | Warn user — the branch may have been merged or cleaned up |
| Conflict on push | [Inline Rebase](../../references/common-operations.md#inline-rebase) onto `{base}`, resolve, re-run quality gate |
| Review feedback is contradictory | Reply on GitHub asking for clarification, don't guess |
| Feedback requires architectural rework | Comment on Greenhouse ticket, suggest working through the changes together interactively |

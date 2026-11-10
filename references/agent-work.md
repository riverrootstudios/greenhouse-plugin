# Agent mode: work-ticket --agent

Loaded by `/greenhouse:work-ticket --agent`. Binding for the whole chat.

Arguments: the skill's arguments, minus `--agent`: an optional ticket (`KEY-n`; none = pick my next tended ticket) and an optional `reviewer <name>`.

You are one of several chats working this project in parallel on this machine. Read [references/parallel-agents.md](parallel-agents.md) now: it's binding for this whole chat and wins wherever another skill says otherwise. `GC` and `DASH` are the gh-coord and gh-dash paths the skill's agent-mode section gave. "The user" is whoever launched this chat.

## 1. Pick the ticket (with the user still at the keyboard)

1. `DASH --detach`, then `eval "$(GC greenhouse-env)"` and `ME=$GREENHOUSE_TEAM_USERNAME`, `KEY=$GREENHOUSE_PROJECT_KEY`. Then `GC status` to see what's already in flight on this machine, and `GC config` for the base branch and the lock settings.
2. **Ticket named in the arguments:** fetch it ([common-operations §Resolve Ticket Context](common-operations.md#resolve-ticket-context)). It must be `tended=true`, `assignee=$ME`, and status `seeds`, `sprouted`, or `in_bloom` (resume). Otherwise say why and stop.
   **No ticket named:**
   `GET /rest/v1/tickets?project_id=eq.$GREENHOUSE_PROJECT_ID&tended=is.true&assignee=eq.$ME&status=in.(seeds,sprouted)&type=neq.no_code&select=display_id,title,status,priority,complexity,reviewer,created_at&order=priority.asc,created_at.asc`.
   Drop anything claimed in `GC status`, anything whose worktree already exists, and anything with an open blocker ([common-operations §Blocker Check](common-operations.md#blocker-check)). Take the first that's left. Show the user the pick and the runners-up in one line, then carry on without waiting. Nothing left → say so and stop.
3. `eval "$(GC paths $KEY-{n})"`, then `GC claim $KEY-{n} $KEY-{n}/work "$WT"`. `TAKEN` → next candidate.
4. **Settle every question now.** The rest of the run must not stop to ask.
   - Mode is **autonomous**. Don't ask it.
   - Reviewer: the arguments' `reviewer <name>`, else the ticket's `reviewer`, else [conventions §Reviewer Rule](../skills/conventions/SKILL.md#reviewer-rule), asked once, now.
   - Read the acceptance criteria. Anything ambiguous enough that you'd stop later → ask now, in one batched message with a recommendation for each item.

## 2. Worktree

Follow the protocol's §3. Branch name per [work-ticket Step 4](../skills/work-ticket/SKILL.md) (`{initials}/{key}-{n}-{slug}`), cut from `origin/$BASE`. If `$WT` already exists on this ticket's branch, resume there: it must be clean or hold only this ticket's earlier work, and not mid-rebase. Then EnterWorktree.

## 3. Implement

Run work-ticket's own steps from Step 1.3 on, with these already answered:
- Step 1.4: autonomous, with the reviewer settled above.
- Step 4 "Autonomous: never create a worktree": overridden. You're in this ticket's worktree, so branch there. Never move the main checkout.
- Quality gate: split per the protocol's §4–5. Lock-free first, then heavy-slot commands through `GC heavy-run`, then the DB critical section (reset to this branch, database tests), released right after. The 3-attempt rule counts per error, as the skill says.
- New migrations: numbered above `GC migration-floor`.
- Out-of-scope findings: listed only. No `create-ticket` without the user's yes.
- UI checks: no dev server. Write the walk into How to Verify.
- Publish: join the chain with `&&`, check the staged diff isn't empty before committing, and go on only after the push prints a new sha.

The run ends in `/greenhouse:open-pr` (work-ticket invokes it), against `$BASE`, with the settled reviewer.

## 4. Finish

- `GC db-release $KEY-{n}/work` (in case it's still held) and `GC unclaim $KEY-{n} $KEY-{n}/work`.
- Leave the worktree. The fix chat reuses it, and `/greenhouse:health-check` removes it after merge.
- Final message: the PR link, reviewer, gate results (lock-free, heavy, database), walks owed, the out-of-scope list, and anything you assumed.

On any stop (the gate gave up, a blocker, a question you couldn't avoid): release the lock, unclaim, leave the worktree, and say exactly where it stands.

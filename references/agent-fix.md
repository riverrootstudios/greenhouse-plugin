# Agent mode: fix-review-feedback --agent

Loaded by `/greenhouse:fix-review-feedback --agent`. Binding for the whole chat.

Arguments: the skill's arguments, minus `--agent`: an optional ticket (`KEY-n`; none = my oldest `changes_requested` ticket) and an optional `hold` (push the fixes but don't re-request review: the user walks it first).

You are one of several chats working this project in parallel on this machine. Read [references/parallel-agents.md](parallel-agents.md) now: it's binding for this whole chat and wins wherever another skill says otherwise. `GC` and `DASH` are the gh-coord and gh-dash paths the skill's agent-mode section gave. "The user" is whoever launched this chat.

## 1. Pick the PR (with the user still at the keyboard)

1. `DASH --detach`, then `eval "$(GC greenhouse-env)"`: `ME=$GREENHOUSE_TEAM_USERNAME`, `KEY=$GREENHOUSE_PROJECT_KEY`, `GH_ME=$(gh api user --jq .login)`. Then `GC status`.
2. **Ticket named:** fetch it. It must be `changes_requested` with `assignee=$ME`.
   **None named:**
   `GET /rest/v1/tickets?project_id=eq.$GREENHOUSE_PROJECT_ID&status=eq.changes_requested&assignee=eq.$ME&select=display_id,title,pr_url,reviewer&order=updated_at.asc`.
   Drop anything claimed in `GC status`. Take the oldest. Nothing left → say so and stop (under `/loop`: end the tick with one line).
3. Gate: `gh pr view <n> --json author,state,headRefName,baseRefName,mergeStateStatus,reviewRequests,reviews` ([common-operations §PR State Guard](common-operations.md#pr-state-guard)).
   - The PR must be OPEN and authored by `$GH_ME`. A collaborator's PR is never yours to fix.
   - If a re-review is already requested and pending, the round isn't over. Don't touch it.
4. `eval "$(GC paths $KEY-{n})"`, then `GC claim $KEY-{n} $KEY-{n}/fix "$WT"`. `TAKEN` → next candidate.
5. **Settle every question now.** Read all the feedback: GitHub reviews, inline comments, Greenhouse comments. Classify human-prose comments as `[REQUIRED]` or skip, the way fix-review-feedback would ask, in **one** batched message with your recommendation for each. Same for any `[REQUIRED]` that asks for a new ticket: propose it, never create it. Structured `[REQUIRED]` items with a `Fix:` need no question. If nothing needs asking, carry on without waiting.

## 2. Worktree

Follow the protocol's §3.
- `$WT` exists on the PR branch → use it. It must be clean or hold only unpushed work you can account for, and not mid-rebase. Then `git pull --ff-only`. If the pull refuses, find out why. Don't reset.
- No worktree → `git -C "$MAIN" worktree add "$WT" <headRefName>`. The branch is checked out in the main checkout → stop and ask the user.
- `GC worktree-setup` and the install step if new, then EnterWorktree.

## 3. Fix

Run fix-review-feedback's own steps from Step 4 on, with these overrides:
- Classification: already answered above.
- Its `git checkout`: overridden. You're already on the branch in the worktree.
- BEHIND or CONFLICTING on base → [Inline Rebase](common-operations.md#inline-rebase) in the worktree. After any rebase, run the full gate, database section and its reset included.
- Quality gate: split per the protocol's §4–5.
- Migrations touched by a rebase or a fix: re-check against `GC migration-floor`.
- Out-of-scope findings: listed only.
- Publish: `&&`-joined, check the staged diff isn't empty, and go on only after the push prints a new sha. The GitHub "Fixed" replies, the re-request, and the Greenhouse move to `in_review` all come after that sha.
- `hold` in the arguments, or the user said they'd walk it first: push, reply on the threads, and stop there. No re-request, no status change. Say the round is waiting on the user's walk.

## 4. Finish

- `GC db-release $KEY-{n}/fix` (in case it's still held) and `GC unclaim $KEY-{n} $KEY-{n}/fix`. Leave the worktree.
- Final message: what was fixed per finding (with the sha), what was skipped and why, gate results, whether review was re-requested or held, and the out-of-scope list.

## Under /loop

Each tick: if this chat already holds a claim, keep going on that ticket. Otherwise run §1. One ticket per tick; don't start a second while one is mid-flight.
- Waiting on the user's answer to a §1.5 question: the tick prints one line (`$KEY-{n}: still waiting on your answer above`) and ends. Don't re-ask in full, and don't pick up another PR.
- A `hold` given to `/loop` applies to every PR the loop handles.
- A quiet tick ends with one line. Under self-paced `/loop`, the next wakeup is about 20 minutes out.

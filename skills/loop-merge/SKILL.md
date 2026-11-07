---
description: One tick of a continuous merge loop. Finds my own approved PRs into the integration branch or an epic branch, applies their merge conditions (code included), rebases, waits for every CI job to be green on the head, and lands them with /greenhouse:merge-pr. Meant for /loop. User-invoked only — run it when the user types /greenhouse:loop-merge, gh-dash starts it, or a /loop tick fires it, never on a general request to merge a PR (use /greenhouse:merge-pr for that).
argument-hint: "[KEY-n | PR#] [dry]"
---

# Loop: continuous merge tick

Arguments: `$ARGUMENTS` (empty = scan my approved PRs; a ticket or PR = just that one; `dry` = report what each PR needs and what this tick would do, with no writes of any kind)

Run under `/loop` (`/loop 5m /greenhouse:loop-merge`, or `/loop /greenhouse:loop-merge` to self-pace). Each invocation is one tick. Other chats on this machine are working, fixing and reviewing tickets in worktrees. Read [references/parallel-agents.md](../../references/parallel-agents.md) now: it's binding for this whole chat and wins wherever another skill says otherwise. `GC` = `${CLAUDE_PLUGIN_ROOT}/bin/gh-coord`. "The user" is whoever launched this chat.

## Hard rules

- Merge only into the integration branch (`BASE` in `GC config`) or `epic/*`. Never `main` when it isn't the integration branch, never `release/*`, never a stacked PR's feature-branch base. Never tag, promote, or open an epic PR.
- Only PRs authored by `$GH_ME`. A collaborator's PR is never yours to merge.
- Never merge content the reviewer didn't see (§2a), except the changes this skill makes to meet the approval's merge conditions (§2c), each mapped to its sha in a PR comment. Never dismiss a review.
- **An approval means do the conditions, then merge.** Never send an approved PR back to `changes_requested` or to a fix chat, and never ask the reviewer to look again. Every CI job green on the head is the gate.
- Never touch `$MAIN` (protocol §2) and never start the dev server. The ticket's worktree is usually all a tick needs. Take the DB lock only for a database-touching change (§3.6), and release it right after.
- Never create a ticket. Never make a behavior change that neither the review nor the user asked for.
- Invoking this skill is the user's go-ahead for merge-pr's confirmation step and for any deploy a merge to the integration branch fires. That go-ahead covers only PRs that pass every gate below.

## 1. Find candidates

1. `${CLAUDE_PLUGIN_ROOT}/bin/gh-dash --detach`, then `eval "$(GC greenhouse-env)"`: `ME=$GREENHOUSE_TEAM_USERNAME`, `KEY=$GREENHOUSE_PROJECT_KEY`, `GH_ME=$(gh api user --jq .login)`. Then `GC status` and `GC config`.
2. `gh pr list --author @me --state open --json number,title,headRefName,baseRefName,reviewDecision,isDraft,labels,mergeStateStatus,headRefOid,body`. Keep the PRs that are `APPROVED`, not a draft, without a `hold` label, and based on `$BASE` or `epic/*`. A ticket or PR in the arguments narrows this to that one.
3. Resolve the ticket from `Implements $KEY-{n}` in the body. It must be `assignee=$ME` and not `harvest` or `weeded`. Drop any ticket claimed in `GC status` under a label other than `$KEY-{n}/merge` (a work or fix chat has it).
4. Nothing left → one line ("nothing approved") and end the tick.
5. Order: this chat's in-flight claim first, then a PR that's CLEAN with CI green on its head (merge it now), then the oldest approval. **One PR in flight at a time.** Don't rebase a second PR while one waits on CI; the merge would make it BEHIND again. Parked PRs don't block the line.

## 2. Gate each candidate (read-only)

Read the ticket's latest `gh-loop merge` comment (§4) if there is one. It holds what earlier ticks recorded: the approved sha, the sha this skill pushed, the head a rerun was spent on, and any parked question.

**a. The approval covers the head.** Take the latest approving review's `commit.oid` (`gh pr view <n> --json reviews,headRefOid`). The head must equal it, or equal the last sha this skill pushed. Otherwise `git -C "$MAIN" fetch origin` and `git range-diff` from the approved commit to the head. It may show only a rebase (patches unchanged) plus this skill's own commits. Anything else → park: "head changed after approval, needs re-review".

**b. Collect the conditions.**
- The approving review's `## Merge conditions` section.
- Noted items that say to do something "at merge" or "before merge" (for example "tick Part D at merge").
- "Before merge" notes in the ticket's Greenhouse comments.

**c. Classify each condition.** The approval already covers the conditions. This chat does them and merges. Nothing goes back to review.
- *Do here, no question:* wording in a file (code comments, docs), the PR title or body, the ticket's title, description or acceptance-criteria text, ticks, "green on the head", "rebase after #X lands", a migration renumber, rebase fallout, and **any code or test change the review spells out** (what to change and where).
- *"File a ticket" for a fix the review already spells out, that fits in a few files:* fold it in here, and note in the PR body that it was folded in at merge.
- *Ask (only these):* a condition that picks between two behaviors or designs the review left open, a fold-in too big to do safely at merge (say what it touches), or anything that needs a person, production, a dashboard, secrets or a device. A walk is never a merge condition; it's owed after merge.
- Ask in one batched message per PR, with a recommendation for each item. The recommended option is "do it here, keep the approval, merge on every CI job green"; filing is the alternative. Record the PR as parked (§4). Later ticks print one line (`$KEY-{n}: still waiting on your answer above`) and keep working other PRs. Before acting on a parked PR, re-read the ticket's latest Greenhouse comments and status: another chat may have recorded a different answer.
- When the user answers:
  - **Do it here / fold it in** → §3 in this chat. The ticket stays `in_review`.
  - **File it** → `/greenhouse:create-ticket`, then link the ticket in the PR body.
  - **Done** (the user ran the production check, looked at the dashboard, and so on) → mark it met.

**d. CI on the head, every job.** Run [common-operations §CI on the Current Head](../../references/common-operations.md#ci-on-the-current-head), then `gh run view <id> --json jobs`. Every job must be `success`, not only the required ones. Pending → wait for a later tick. On a failure, run `gh run rerun <id> --failed` once per head sha and record that the rerun was spent. A second failure on the same head → park, name the failing test, and propose a flake ticket. Don't create it.

**e. Freshness.** `mergeStateStatus` BEHIND or DIRTY → it needs a rebase (§3).

`dry` stops here: print each PR's gates, its conditions with their class, and the step this tick would take.

## 3. Apply (the one PR in flight)

1. `eval "$(GC paths $KEY-{n})"`, then `GC claim $KEY-{n} $KEY-{n}/merge "$WT"`. `TAKEN` → skip it this tick.
2. Worktree, per the protocol's §3:
   - `$WT` exists on the PR branch → it must be clean or hold only unpushed work you can account for, and not mid-rebase. Then `git pull --ff-only`. If the pull refuses, find out why. Don't reset.
   - No worktree → `git -C "$MAIN" worktree add "$WT" <headRefName>`, then `GC worktree-setup "$WT"` and the install step there. The branch is checked out in `$MAIN` → park and ask.
   - **Don't EnterWorktree.** This chat moves between tickets and removes worktrees after merge. Prefix every Bash command with `cd "$WT" &&`, use absolute `$WT` paths for Read and Edit, and check `pwd` and `git branch --show-current` before every commit.
3. BEHIND or DIRTY → [Inline Rebase](../../references/common-operations.md#inline-rebase) onto `origin/<base>`. Resolve only mechanical conflicts: the lockfile (regenerate it), migration numbering, both sides adding imports or list entries. A conflict that chooses between two behaviors → `git rebase --abort`, park, ask.
4. Migrations: if one of the PR's migrations is at or below the highest on `origin/<base>`, renumber it above `GC migration-floor` and fix references to the old name. If one replaces a function the base also changed since the branch point → park.
5. Apply the conditions: files, `gh pr edit` for the title and body, a Greenhouse PATCH for this ticket's fields.
6. Local checks scale with the change:
   - Wording only, or a clean rebase: none. CI is the gate.
   - Other file changes (a resolved conflict, a code condition): the project's lint, plus typecheck through `GC heavy-run` when typed code changed. Run each new or changed test, and mutation-check it: break the line it guards, see it fail, restore. Regenerate any generated files the change needs (CLAUDE.md lists them) in the same commit.
   - A database-touching change (a migration renumber, a resolved conflict in migrations, policies, generated database files, or database tests): run the lock-free checks first. Then the protocol's §5 critical section under `$KEY-{n}/merge`: `db-acquire` (`db-wait` in the background if HELD), `db-stack`, reset to this branch, any generator the change needs, then the database tests (all of them after a renumber, the touched ones otherwise). `GC db-release $KEY-{n}/merge` right after, pass or fail.
   - A check fails and the fix isn't mechanical → park and ask.
7. Publish: join the chain with `&&`. Check the staged diff isn't empty, commit `chore: review r{N} merge conditions [$KEY-{n}]` (skip the commit after a rebase-only pass), then `git push` (`--force-with-lease` after a rebase; the approval survives it). Go on only once the push prints a new sha, and record that sha (§4). If conditions were applied:
   - post one PR comment that maps each condition to the sha, so the reviewer can see what changed after their approval;
   - add a line to the PR body, `Merge conditions applied at merge; CI is the gate.`, and put the same sentence in this tick's Greenhouse record comment (§4);
   - leave the ticket `in_review`. It never goes back to `changes_requested`.
8. End the tick with CI pending. Keep the claim.

## 4. Merge

Merge when all of these hold: the head equals the approved sha or the sha this skill recorded, every CI job is green on it, the PR isn't BEHIND or DIRTY, and every condition is met or answered. Re-read `mergeStateStatus` right before merging: the base may have moved, in which case go back to §3.

Invoke `/greenhouse:merge-pr <PR#>` with these overrides:
- The confirmation is already answered. Its condition list is the one §2 verified, and its CI gate is §2d (every job).
- Branch cleanup: never checkout or pull in `$MAIN`. Instead `git -C "$MAIN" fetch origin`, then `git -C "$MAIN" worktree remove "$WT"` if it's clean (otherwise leave it and say so). Once the PR reads MERGED, `git -C "$MAIN" branch -D <branch>` (a squash isn't an ancestor, so `-d` refuses), and `git push origin --delete <branch>` if GitHub kept it.
- Harvest as written, and tick the acceptance criteria the review said to tick at merge. Epic check: report progress only, never open the epic PR.
- No "pick up the next ticket?" prompt.

Then `GC unclaim $KEY-{n} $KEY-{n}/merge`, and go on to the next candidate in the same tick: the rest are now BEHIND.

**Record** each tick's progress on a PR in one Greenhouse comment on its ticket (comment pattern in [common-operations](../../references/common-operations.md#posting-comments-and-patching-multi-line-ticket-fields), `author` `${GREENHOUSE_TEAM_USERNAME}`): what this tick did, plus a marker the next tick reads.

```
Loop merge: {rebased and pushed {short sha}, CI pending | conditions applied at {short sha} | parked: {question} | merged at {squash sha}; walk owed: {walk}}

[//]: # (gh-loop merge approved={sha} pushed={sha} rerun={sha or -} parked={yes|no})
```

## 5. Tick summary

One line per PR: merged (squash sha), CI pending (run id, minutes so far), parked (why, and what answer is needed), or skipped (why). A quiet tick is one line.

On any stop (a gate you can't pass, an error, a question): `git rebase --abort` if mid-rebase, `GC db-release $KEY-{n}/merge` if held, `GC unclaim $KEY-{n} $KEY-{n}/merge`, leave the worktree, and say exactly where it stands.

Under self-paced `/loop`: about 5 minutes while CI is pending, 20–30 minutes when nothing is approved.

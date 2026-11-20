# Agent mode: review-pr --agent

Loaded by `/greenhouse:review-pr --agent`. Binding for the whole chat.

Arguments: the skill's arguments, minus `--agent` (empty = scan the queue; a ticket or PR = review just that one)

Run under `/loop` (`/loop 5m /greenhouse:review-pr --agent`, or `/loop /greenhouse:review-pr --agent` to self-pace). Each invocation is one tick. Other chats on this machine are working tickets in worktrees and sharing the local database through gh-coord ([references/parallel-agents.md](parallel-agents.md)). This chat stays out of their way. `GC` and `DASH` are the gh-coord and gh-dash paths the skill's agent-mode section gave. "The user" is whoever launched this chat.

## Hard rules (review only)

- Never `checkout`, `switch`, `pull`, `rebase`, `reset`, `stash`, or edit files, in any checkout or worktree. Never run fix-review-feedback or merge-pr from here.
- Never touch the local database: no tests, no resets, no `psql`, no dev server. Anything that needs a running app becomes a walk in the review, owed by the user or the author.
- Read code with `gh pr diff`, `gh api`, and `git fetch origin <branch>` + `git show origin/<branch>:<path>`. Fetch is the only git write allowed.

## 1. Find what's waiting on me

0. Under `/loop`, the tick's first command is `GC tick` and its last is `GC tick <minutes to the next tick>` ([parallel-agents §9](parallel-agents.md#9-under-loop)). A one-shot run skips both.
1. `DASH --detach`, then `eval "$(GC greenhouse-env)"`: `ME=$GREENHOUSE_TEAM_USERNAME`, `KEY=$GREENHOUSE_PROJECT_KEY`, `GH_ME=$(gh api user --jq .login)`, and my initials from `org_avatar_directory` ([conventions §Current user resolution](../skills/conventions/SKILL.md#current-user-resolution)). Older tickets may carry any of the three in `reviewer`, so `ALIASES=$ME,<initials>,$GH_ME`.
2. Query:
   `GET /rest/v1/tickets?project_id=eq.$GREENHOUSE_PROJECT_ID&status=eq.in_review&or=(reviewer.in.($ALIASES),reviewer.is.null)&select=id,display_id,title,pr_url,reviewer,assignee,updated_at&order=updated_at.asc`
   - `reviewer` null → keep it only if `gh pr view <n> --json reviewRequests` requests `$GH_ME`. A null reviewer is never assumed mine.
   - Skip PRs authored by `$GH_ME`.
3. For each candidate, read `gh pr view <n> --json headRefOid,state,baseRefName,mergeStateStatus,reviews,reviewRequests,isDraft` and the ticket's latest `gh-loop review` comment (see §4). Skip when:
   - the PR isn't OPEN, or is a draft;
   - that comment records this head sha as posted;
   - `GC status` shows a claim on the ticket (a fix chat is about to move the head, so wait for its push);
   - the head moved only by a force-push after my APPROVE (a rebase, same content): the approval survives, so check CI at the new head and note it instead of re-reviewing.
4. Nothing left → one line ("queue clear") and end the tick. Otherwise work through them, oldest first.

## 2. Review it

1. `GC claim $KEY-{n} $KEY-{n}/review -`. `TAKEN` → skip it this tick.
2. Run review-pr's Steps 1–3 on it. A stacked PR (base isn't the integration branch) is reviewed against its base and re-verified after the base lands.
3. Stale-base check, every round (it belongs in the verdict):
   - BEHIND or CONFLICTING on base;
   - a CI run exists at the head sha ([common-operations §CI on the Current Head](common-operations.md#ci-on-the-current-head));
   - any new migration's version is above the integration branch's highest.

## 3. Post, then ask

The tick does all of its person-free work first, then asks, then waits.

1. **No judgment items:** `--agent` is the user's go-ahead for review-pr's posting gate. Post the verdict (APPROVE, APPROVE with merge conditions, or REQUEST_CHANGES), record it (§4), and `GC unclaim $KEY-{n} $KEY-{n}/review`. Go on to the next PR.
2. **Judgment items** (review-pr's Step 2f): hold this PR's verdict and keep its claim. Post one PR comment for the round, so the author can see why no verdict came: `Review r{N} at {short sha} is waiting on {user}'s decision: {one line}.` A PR left for this tick by an earlier one (step 3) already has it: when `gh pr view <n> --json comments` shows a comment starting `Review r{N} at {short sha} is waiting`, don't post another. Then go on to the next PR.
3. **Once every PR this tick could finish is posted,** ask every judgment item the tick found in one box ([common-operations §Asking the User](common-operations.md#asking-the-user)): each item a decision brief above the box, one question per item, header and question starting with the ticket key. A box holds up to 4 questions: with more, ask the 4 oldest and leave the rest for the next tick (their PRs are released unposted, and the next tick reviews them again).
4. **Wait for the answer.** The tick doesn't end, and no other tick fires, while the box is open. A box that comes back unanswered is asked again in a fresh box, never decided.
5. With the answers in: finish each held review, post its verdict (it supersedes the waiting comment), record it with the decision and its reason (§4) before the tick ends, and unclaim.

Never create a follow-up ticket. Propose it in the review, or as an option in the box.

## 4. Record

One Greenhouse comment on the ticket per round, so the next tick (or a teammate) can see where review stands. Use the comment pattern in [common-operations](common-operations.md#posting-comments-and-patching-multi-line-ticket-fields), with `author` `${GREENHOUSE_TEAM_USERNAME}`:

```
Loop review r{N} at {short sha}: {APPROVE | APPROVE with merge conditions | REQUEST_CHANGES}, posted. {required} required, {noted} noted. {walks owed / merge conditions, one line each}
{Decided by {user}: {decision} → {answer}, because {reason}. — one line per answered item, when there were any}

[//]: # (gh-loop review head={full sha} state=posted)
```

Tick summary: what was reviewed (PR, sha, verdict), what the user decided, what was skipped and why, and which items were left for the next tick.

Under self-paced `/loop`: about 5 minutes when something is waiting on another person's push, 20–30 minutes when the queue is clear.

# Agent mode: review-pr --agent

Loaded by `/greenhouse:review-pr --agent`. Binding for the whole chat.

Arguments: the skill's arguments, minus `--agent` (empty = scan the queue; a ticket or PR = review just that one)

Run under `/loop` (`/loop 5m /greenhouse:review-pr --agent`, or `/loop /greenhouse:review-pr --agent` to self-pace). Each invocation is one tick. Other chats on this machine are working tickets in worktrees and sharing the local database through gh-coord ([references/parallel-agents.md](parallel-agents.md)). This chat stays out of their way. `GC` and `DASH` are the gh-coord and gh-dash paths the skill's agent-mode section gave. "The user" is whoever launched this chat.

## Hard rules (review only)

- Never `checkout`, `switch`, `pull`, `rebase`, `reset`, `stash`, or edit files, in any checkout or worktree. Never run fix-review-feedback or merge-pr from here.
- Never touch the local database: no tests, no resets, no `psql`, no dev server. Anything that needs a running app becomes a walk in the review, owed by the user or the author.
- Read code with `gh pr diff`, `gh api`, and `git fetch origin <branch>` + `git show origin/<branch>:<path>`. Fetch is the only git write allowed.

## 1. Find what's waiting on me

1. `DASH --detach`, then `eval "$(GC greenhouse-env)"`: `ME=$GREENHOUSE_TEAM_USERNAME`, `KEY=$GREENHOUSE_PROJECT_KEY`, `GH_ME=$(gh api user --jq .login)`, and my initials from `org_avatar_directory` ([conventions §Current user resolution](../skills/conventions/SKILL.md#current-user-resolution)). Older tickets may carry any of the three in `reviewer`, so `ALIASES=$ME,<initials>,$GH_ME`.
2. Query:
   `GET /rest/v1/tickets?project_id=eq.$GREENHOUSE_PROJECT_ID&status=eq.in_review&or=(reviewer.in.($ALIASES),reviewer.is.null)&select=id,display_id,title,pr_url,reviewer,assignee,updated_at&order=updated_at.asc`
   - `reviewer` null → keep it only if `gh pr view <n> --json reviewRequests` requests `$GH_ME`. A null reviewer is never assumed mine.
   - Skip PRs authored by `$GH_ME`.
3. For each candidate, read `gh pr view <n> --json headRefOid,state,baseRefName,mergeStateStatus,reviews,reviewRequests,isDraft` and the ticket's latest `gh-loop review` comment (see §4). Skip when:
   - the PR isn't OPEN, or is a draft;
   - that comment records this head sha as reviewed, drafted-awaiting-user, or posted;
   - `GC status` shows a claim on the ticket (a fix chat is about to move the head, so wait for its push);
   - the head moved only by a force-push after my APPROVE (a rebase, same content): the approval survives, so check CI at the new head and note it instead of re-reviewing.
4. Nothing left → one line ("queue clear") and end the tick. Otherwise take the oldest first.

## 2. Review it

1. `GC claim $KEY-{n} $KEY-{n}/review -`. `TAKEN` → skip it this tick.
2. Run review-pr's Steps 1–3 on it. A stacked PR (base isn't the integration branch) is reviewed against its base and re-verified after the base lands.
3. Stale-base check, every round (it belongs in the verdict):
   - BEHIND or CONFLICTING on base;
   - a CI run exists at the head sha ([common-operations §CI on the Current Head](common-operations.md#ci-on-the-current-head));
   - any new migration's version is above the integration branch's highest.

## 3. Post or ask

- **No judgment items:** `--agent` is the user's go-ahead for review-pr's posting gate. Post the verdict (APPROVE, APPROVE with merge conditions, or REQUEST_CHANGES), then record it (§4).
- **Judgment items:** don't post. Draft the verdict, record the sha as drafted-awaiting-user, and ask the user one batched question with your recommendation for each item. Keep ticking other PRs. When the user answers, post that one.
- Never create a follow-up ticket. Propose it in the review or in the question.

Then `GC unclaim $KEY-{n} $KEY-{n}/review`.

## 4. Record

One Greenhouse comment on the ticket per round, so the next tick (or a teammate) can see where review stands. Use the comment pattern in [common-operations](common-operations.md#posting-comments-and-patching-multi-line-ticket-fields), with `author` `${GREENHOUSE_TEAM_USERNAME}`:

```
Loop review r{N} at {short sha}: {APPROVE | APPROVE with merge conditions | REQUEST_CHANGES} ({posted | drafted, waiting on {user}}). {required} required, {noted} noted. {walks owed / merge conditions, one line each}

[//]: # (gh-loop review head={full sha} state={posted|drafted})
```

Tick summary: what was reviewed (PR, sha, verdict, posted or waiting on the user), what was skipped and why, and what needs the user's answer.

Under self-paced `/loop`: about 5 minutes when something is waiting on another person's push, 20–30 minutes when the queue is clear.

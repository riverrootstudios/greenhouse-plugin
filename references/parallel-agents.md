# Parallel agents on one machine

**Used by:** the `--agent` mode of `work-ticket`, `fix-review-feedback`, `review-pr` and `merge-pr` (GH-129). Binding on every chat that runs one of them with `--agent`, and it wins wherever another skill says otherwise.

Several Claude Code chats work the same project at once on one machine: some implement tickets, some fix review feedback, one reviews, one merges. Three things on the machine can't be shared safely:

- **The main checkout.** It's the user's own working copy. A chat that switches branches there wrecks whatever the user is doing.
- **The local database stack** (when the project has one). One set of ports and one database: every reset replaces the schema for everyone, and two test runs against it destroy each other's data.
- **CPU and memory.** Two builds alongside a database test run can run a laptop out of memory and take the editor down.

So every chat works in its own git worktree, and everything shared goes through the coordinator, `gh-coord` (it ships in the plugin's `bin/`, which Claude Code puts on the Bash tool's PATH). `GC` below means `gh-coord`. "The user" means whoever launched the chat.

`gh-coord config` prints the project's settings: `KEY` (ticket prefix), `BASE` (integration branch), `LOCAL_STACK` (empty means the project has no local database and the DB lock is off), `DB_COMMANDS` and `HEAVY_COMMANDS`. They come from the repo's CLAUDE.md `greenhouse` block (see [conventions](../skills/conventions/SKILL.md)).

---

## 1. Your identity in the coordinator

- **Dashboard first:** `gh-dash --detach` (a no-op when it's already running). It's how Greenhouse sees this machine's chats and how a ticket page starts chats here.
- **Paths:** `eval "$(GC paths {KEY}-{n})"` gives `$MAIN` (the main checkout) and `$WT`, the ticket's worktree: `$MAIN/.claude/worktrees/{key}-{n}` (GH-134), where EnterWorktree goes in without a permission prompt. `GC paths` also keeps that folder out of the main checkout's `git status` (a line in `.git/info/exclude`). A ticket whose worktree already sits beside the main checkout (`<repo>-{n}`, the old place) keeps it. `$WT` is the same for the ticket's whole life, shared by its work, fix and merge chats in turn.
- **Label:** `{KEY}-{n}/work`, `{KEY}-{n}/fix`, `{KEY}-{n}/review` or `{KEY}-{n}/merge`.
- **Claim before touching anything:** `GC claim {KEY}-{n} <label> "$WT"`. `TAKEN` means another chat has it: leave that ticket alone, pick another or stop. `GC unclaim {KEY}-{n} <label>` on every way out: done, handed off or gave up.
- **Your chat is recorded for you.** Every `GC` call from a Claude Code chat updates its record: `claim` sets its ticket and role, and `db-wait`, `db-run` and `heavy-run` set what it's running. The plugin's hooks mark it as needing someone: an `AskUserQuestion` box sets `question` when it opens and clears it when it's answered (GH-134), and a Notification (`permission_prompt`, `elicitation_dialog`, `agent_needs_input`, or `idle_prompt` after a minute waiting on input) sets its own kind. A Notification never downgrades an open box's `question` to `idle` or restarts its wait, so a loop waiting on a box stays on the Agents page's Waiting list until it's answered. Nothing extra to call.
- **Greenhouse:** `eval "$(GC greenhouse-env)"` authenticates (`gh-jwt`) and exports `GREENHOUSE_PROJECT_ID` and `GREENHOUSE_PROJECT_KEY`.
- **No `eval` inside the worktree.** Once a chat has called EnterWorktree, Claude Code refuses any command it can't check stays inside the worktree, and `eval "$(…)"` is one of them, so `eval "$(gh-jwt)"`, `eval "$(GC greenhouse-env)"` and `eval "$(GC paths …)"` stop working there. Shell variables don't survive between Bash calls either. So, inside the worktree:
  - Read the values once with plain commands and write them into later commands literally: `GC paths {KEY}-{n}` (`MAIN`, `WT`), `GC config` (`KEY`, `PROJECT_ID`, `BASE`), `gh-api whoami` (`GREENHOUSE_ORG_ID`, `GREENHOUSE_TEAM_USERNAME`; it never prints the token).
  - Call Greenhouse with `gh-api <METHOD> <path> [<payload file> | - | <json>]` instead of `eval "$(gh-jwt)"` plus curl. It sends the same headers and curl flags, asks for the written rows back on writes, and exits 1 with the response on stderr when the call fails.
  - Write multi-line payloads (comment bodies, criteria) to a file with the Write tool, then build the JSON with `jq --rawfile` as [common-operations](common-operations.md#posting-comments-and-patching-multi-line-ticket-fields) shows. A heredoc can be refused for the same reason as `eval`.
  - Call the plugin's tools by name (`gh-coord`, `gh-api`, `gh-dash`; the plugin's `bin/` is on the PATH) or by their literal path, never through a variable like `$GC`.
- **Naming:** a chat started from gh-dash or a ticket page already has its name (`{key}-{n}` for work, `{key}-{n} {kind}` otherwise). A skill can't rename its own chat. When a chat started by hand has no name, print the `/rename` line for the user once and carry on.

## 2. The main checkout is off limits

- Never `checkout`, `switch`, `pull`, `stash`, `reset`, `rebase` or edit files in `$MAIN`. The user or another chat may be mid-work there.
- Git commands that only touch the shared `.git` are fine with `git -C "$MAIN"`: `fetch`, `worktree add`, `worktree list`. If one fails on a `*.lock` file, another chat is mid-git: retry once after a few seconds. Never delete a lock file.
- If the branch you need is checked out in `$MAIN`, `git worktree add` refuses. Stop and ask the user. Never switch their checkout.

## 3. Getting into the worktree

```bash
git -C "$MAIN" fetch origin
# new branch (work):
git -C "$MAIN" worktree add -b <branch> "$WT" "origin/$BASE"
# existing PR branch (fix, merge):
git -C "$MAIN" worktree add "$WT" <branch>
# first time only, either way (lock-free):
GC worktree-setup "$WT"        # copies the gitignored .env* files from $MAIN
```

Then run the project's install step from CLAUDE.md's Common Commands inside `$WT` (a frozen-lockfile install), and call **EnterWorktree with `path: $WT`** so every later Bash, Read and Edit happens there. A worktree under `$MAIN/.claude/worktrees/` goes in without a prompt; one beside the main checkout (the old place) asks the user first, every time. If EnterWorktree refuses the path, prefix every Bash command with `cd "$WT" &&` and use absolute `$WT` paths for Read and Edit. Before every commit, check that `pwd` and `git branch --show-current` are the worktree and the ticket's branch.

## 4. What needs a lock

The quality gate is CLAUDE.md's Common Commands (common-operations §Quality Gate). Split it three ways:

- **Lock-free, any time, in parallel with everyone:** editing, lint, targeted test files that don't touch the database, git in your own worktree, `gh`, Greenhouse.
- **A heavy slot** (one machine-wide by default): typecheck, build and the full non-database test run, plus anything in `HEAVY_COMMANDS`. Wrap each: `GC heavy-run <label> -- <cmd>`. It waits for a free slot (run it with Bash `run_in_background: true` if you have other work), heartbeats while the command runs, and frees the slot when it exits. A slot whose process died is reclaimed.
- **The DB lock:** anything that reads or writes the local database, plus anything in `DB_COMMANDS`: resets, seeds, migrations, database test runs, `psql`, the stack's start and stop. Reading the database without the lock can mislead you too: the schema belongs to whichever branch reset it last.

Never start the app's dev server. Ports and the database are shared. A UI check becomes a walk for a person, written into the PR's How to Verify.

When `LOCAL_STACK` is empty the DB lock is off: `db-acquire` and `db-wait` return at once and `db-run` just runs the command. Keep the same shape anyway, so the order of work doesn't depend on the project.

## 5. The DB critical section

Hold the lock for one tight sequence, never while you think or write code:

1. Do all the lock-free and heavy-slot work first, and get it green.
2. `GC db-acquire <label> "$WT" "<why>"`.
   - `ACQUIRED` → step 3.
   - `HELD` → run `GC db-wait <label> "$WT" "<why>"` **with Bash `run_in_background: true`**. Keep doing lock-free work, or wait for its completion notice. No `sleep` polling. When it prints `ACQUIRED`, go on.
3. `GC db-stack`:
   - `up` or `none` → fine.
   - `down` → start the stack from your worktree.
   - `other:<project>` → another project holds the ports. Release the lock and ask the user. Never stop another project's stack.
4. **Reset to your branch first**, under `GC db-run <label> -- <reset/seed command>`. Someone else's branch was loaded before you; a reset is the only way your migrations and policies are what the tests see.
5. `GC db-run <label> -- <database tests>`. One database test command at a time. `db-run` keeps your heartbeat fresh.
6. `GC db-release <label>`, **immediately**, pass or fail. Then read the failures and fix them lock-free.
   - Exception: if `GC status` shows nobody waiting, you may keep the lock for a quick fix-and-rerun (20 minutes at most). The moment a waiter appears, release.
7. Release on every way out: success, error, giving up, handing off. A lock left behind blocks every other chat until it goes stale (30 minutes with no heartbeat and nothing running in your worktree, or your worktree deleted), when the next acquire breaks it.

Stack trouble while holding the lock: restart the whole stack, never one container (the gateway caches upstream addresses and the stack desyncs). If Docker hangs, check free disk space first.

## 6. Migrations across parallel branches

Before creating a migration, run `GC migration-floor`: the highest migration version across `origin/$BASE` and every worktree on this machine. Number yours above it. Parallel branches that number from the same base collide at merge.

## 7. Shared memory files

Other chats write memory at the same time. Edit a memory index only with Edit (a one-line insert or change), re-read it right before, and never Write the whole file. Progress a later chat needs (the approved sha, what a tick pushed, a decision the user made and why) goes in the ticket's Greenhouse comments, where every chat and every teammate can read it.

## 8. The user's own database use

When the user resets or tests from the main checkout, they take the lock too: `GC db-acquire "$USER" "$MAIN" manual` … `GC db-release "$USER"`. After any chat ran, the database holds that chat's branch: reset again in the main checkout before trusting what you see there.

## 9. Under `/loop`

Review, fix and merge chats run under `/loop`: `/loop 5m /greenhouse:review-pr --agent`, `/loop 5m /greenhouse:fix-review-feedback --agent` or `/loop 5m /greenhouse:merge-pr --agent` (leave out the interval to self-pace). Each invocation is one tick.

- **Stamp the tick, at both ends.** A tick's first command is a plain `GC tick`, so "last ran" moves as soon as it starts. It clears the due time: a running tick has none, so one that spends 20 minutes on a quality gate or a large diff never reads as stopped. Its last command, after any box is answered and right before a self-paced loop schedules its wakeup, is `GC tick <minutes to the next tick>`: the loop's interval, or for a self-paced loop the delay it has just chosen. Only this end stamp sets when the next tick is due. The Agents page reads a loop as stopped once two of its intervals pass with no tick, so the due time has to be measured from the end of the tick: a self-paced loop that goes from 5 minutes to 25, or a tick that spent half an hour on a box, would otherwise read as stopped while it sleeps. A one-shot `--agent` run stamps nothing.
- **Settle what you can at the start**, while the user is still at the keyboard.
- **Person-free work first, then one box.** A tick does everything it can without a person first: posting clean verdicts, merging green PRs, fixing structured `[REQUIRED]` items. Then it asks every judgment item it found in one box ([common-operations §Asking the User](common-operations.md#asking-the-user)), each a decision brief, and waits for the answer before the tick ends. A box holds up to 4 questions; a tick with more asks the 4 oldest and the rest next tick.
- **The loop waits on the box.** A scheduled tick fires only while the chat is idle, so an open box holds the loop: no stacked ticks, and nothing decided behind the user's back. A box that comes back unanswered is asked again, never decided. There's no parking a question and no "still waiting" line.
- **Record the answer before the tick ends**: the ticket's round comment, and the PR body when it changes the PR. A chat that dies after the answer doesn't lose it.
- A quiet tick (nothing to do) is one line.

## 10. Walking away

Loops wait on their boxes, so you can leave them running and answer from your phone. Set this up once per machine:

- **Remote Control for every session**: `"remoteControlAtStartup": true` in `~/.claude/settings.json` (or the same toggle in VS Code's Claude Code settings). Chats are listed under **Code** in the Claude app, and a box reaches your phone as a push notification.
- **In `~/.claude/settings.json`**: `"askUserQuestionTimeout": "never"`, so the app never moves on from an unanswered box (a box that lapses is asked again anyway, never decided), and `"inputNeededNotifEnabled": true` for the push. If an answer from your phone after 5+ minutes doesn't reach the chat, add `"dialogExpiry": "never"` too.
- **Keep the lid open.** gh-dash keeps the Mac awake (`caffeinate -is`, shown as "keeping awake" on its page) while any agent chat is open, but closing the lid still sleeps it.
- **Stop a loop by sending it a message.** Run `/remote-control` to reconnect a chat after a 30-minute disconnect. `/loop` jobs expire after 7 days.
- The Greenhouse Agents page lists what's waiting on whom and for how long, flags a loop that missed two ticks, and (Profile → Agent wait alert) raises a browser alert in any open tab when one of your chats has waited past your threshold.

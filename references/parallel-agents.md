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
- **Paths:** `eval "$(GC paths {KEY}-{n})"` gives `$MAIN` (the main checkout) and `$WT`, the ticket's worktree: a sibling of the main checkout named `<repo>-{n}`. `$WT` is the same for the ticket's whole life, shared by its work, fix and merge chats in turn.
- **Label:** `{KEY}-{n}/work`, `{KEY}-{n}/fix`, `{KEY}-{n}/review` or `{KEY}-{n}/merge`.
- **Claim before touching anything:** `GC claim {KEY}-{n} <label> "$WT"`. `TAKEN` means another chat has it: leave that ticket alone, pick another or stop. `GC unclaim {KEY}-{n} <label>` on every way out: done, handed off or gave up.
- **Your chat is recorded for you.** Every `GC` call from a Claude Code chat updates its record: `claim` sets its ticket and role, and `db-wait`, `db-run` and `heavy-run` set what it's running. When Claude Code raises a Notification for the chat (`permission_prompt`, `elicitation_dialog`, `agent_needs_input`, or `idle_prompt` after a minute waiting on input), the plugin's hook marks it as needing someone. Nothing extra to call.
- **Greenhouse:** `eval "$(GC greenhouse-env)"` authenticates (`gh-jwt`) and exports `GREENHOUSE_PROJECT_ID` and `GREENHOUSE_PROJECT_KEY`.
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

Then run the project's install step from CLAUDE.md's Common Commands inside `$WT` (a frozen-lockfile install), and call **EnterWorktree with `path: $WT`** so every later Bash, Read and Edit happens there. If EnterWorktree refuses the path, prefix every Bash command with `cd "$WT" &&` and use absolute `$WT` paths for Read and Edit. Before every commit, check that `pwd` and `git branch --show-current` are the worktree and the ticket's branch.

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

Other chats write memory at the same time. Edit a memory index only with Edit (a one-line insert or change), re-read it right before, and never Write the whole file. Progress a later chat needs (the approved sha, a parked question, what a tick pushed) goes in the ticket's Greenhouse comments, where every chat and every teammate can read it.

## 8. The user's own database use

When the user resets or tests from the main checkout, they take the lock too: `GC db-acquire "$USER" "$MAIN" manual` … `GC db-release "$USER"`. After any chat ran, the database holds that chat's branch: reset again in the main checkout before trusting what you see there.

## 9. Under `/loop`

Review, fix and merge chats run under `/loop`: `/loop 5m /greenhouse:review-pr --agent`, `/loop 5m /greenhouse:fix-review-feedback --agent` or `/loop 5m /greenhouse:merge-pr --agent` (leave out the interval to self-pace). Each invocation is one tick. Settle every question at the start of a chat, while the user is still at the keyboard; after that a tick never stops to ask. A question that comes up later is asked once, in one batched message with a recommendation for each item. Later ticks print one line (`{KEY}-{n}: still waiting on your answer above`) and keep working other tickets. A quiet tick (nothing to do) is one line.

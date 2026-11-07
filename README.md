# Greenhouse — Dev Workflow Plugin for Claude Code

> **This repository is a read-only mirror.** It is generated from a private repository on every release, so pull requests here can't be merged — but **issues are welcome**: bug reports, questions and ideas all land with the people who build it.

Greenhouse is RiverRoot Studios' project board for software teams: tickets with acceptance criteria, complexity scores and review handoffs, backed by Supabase. This Claude Code plugin is how work moves through it. Greenhouse is the board, GitHub is the code, and the plugin's skills bridge the two — from planning a ticket to opening, reviewing and merging its PR, to cutting a release.

**The rule:** No code without a ticket. No merge without a review. Every commit traces back to a Greenhouse ticket.

Works in Claude Code (CLI, IDE extensions, desktop Code tab). The skills run shell scripts, `git` and `gh`, so plain claude.ai chat can't run them.

---

## Accounts

Greenhouse accounts are **invite-only**. An admin of your Greenhouse organization invites you from the web app; there is no self-service signup. Once you're in, you generate your own CLI token — see [Getting started](#getting-started).

---

## Installation

```bash
/plugin marketplace add riverrootstudios/greenhouse-plugin
/plugin install greenhouse@riverroot
```

This repository is public, so fetching the plugin needs no GitHub credentials. Then connect it to your account:

```bash
/greenhouse:setup
```

### Install for a whole project

Commit a `.claude/settings.json` to the project repo and the plugin **auto-installs for everyone who opens the repo and trusts the folder** — no commands:

```json
{
  "extraKnownMarketplaces": {
    "riverroot": {
      "source": { "source": "github", "repo": "riverrootstudios/greenhouse-plugin" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "greenhouse@riverroot": true }
}
```

Keep `autoUpdate: true`: Claude Code leaves auto-update **off** by default for marketplaces other than the official one, and without it new releases never reach installed copies. Releases are picked up by version, so each release arrives without a manual cache clear.

**Re-pointing an existing install:** if a project's settings point the `riverroot` marketplace at a different repository, change `extraKnownMarketplaces.riverroot.source.repo` to `riverrootstudios/greenhouse-plugin`. Claude Code notices the changed source and re-fetches the marketplace by itself.

### Config Setup

Project config is embedded directly in the project's `CLAUDE.md` (committed to git — no per-machine config file needed). The `greenhouse` fenced code block contains `project_id`, `project_key`, and `org_id`. Everything else is derived at runtime: who you are from your token, repo from git, and assignee/reviewer candidates from the CLAUDE.md Team table (`| Greenhouse | GitHub |`).

Connection values resolve automatically: `GREENHOUSE_URL` and `GREENHOUSE_PUBLIC_KEY` (both non-secret — the same values the web app ships to every browser) come with the plugin; your personal `GREENHOUSE_API_KEY` lands in `~/.greenhouse/config` when you run `/greenhouse:setup`. An environment variable always overrides both (handy for one-shot org switching).

Add the config block by hand when adopting a project — [templates/greenhouse/claude.md.template](templates/greenhouse/claude.md.template) has the full section — and run `/greenhouse:health-check` to verify or repair it.

### Prerequisites

- [Claude Code](https://claude.com/claude-code) installed (v1.0.33+)
- A Greenhouse account (via an invite email) — you generate your own CLI token after signing in
- `gh` CLI authenticated (`gh auth login`) — only for the skills that touch GitHub (opening, reviewing and merging PRs, releases). Installing the plugin doesn't need it
- `pnpm` installed (for projects with a JS quality gate)

No `GREENHOUSE_*` environment variables or PATH edits are required — `/greenhouse:setup` handles credentials.

---

## Getting started

**Self-service, like a GitHub personal access token:**

1. **An admin invites you** in the web app (Settings → Members) and grants project access (Settings → Projects). An email arrives with an **Activate & Sign In** link.
2. **Activate** — click the link to create your account (magic link; no password).
3. **Install Claude Code**, and run `gh auth login` if you'll open or review PRs.
4. **Open the project repo** — the plugin auto-installs on the folder-trust prompt (or install it by hand, above).
5. **Generate a token** in the web app under **Profile → CLI Access**, run `/greenhouse:setup`, and paste it. Done — every skill now authenticates as you.

**Admin notes:**
- A `member`-role teammate only sees projects they're granted — enforced by RLS on both the web app and the plugin. `admin`/`owner` see everything. A member with no grants can't generate a working token until you grant one.
- The token is a `ghk_live_` key bound to the user and scoped live to their current grants; change a grant and their access follows within the hour.
- Removing a member automatically revokes their personal keys.
- To convert an existing repo, commit the `.claude/settings.json` above and add a `greenhouse` config block to its CLAUDE.md.

---

## You Don't Need Slash Commands

Just talk naturally. Claude figures out which skill to use.

| You say | What happens |
|---------|-------------|
| "start working on RG-42" | Picks up the ticket, plans, branches, implements |
| "implement RG-42 autonomously" | Fire-and-forget: ticket → PR, no hand-holding |
| "open a PR" | Pushes, creates PR, assigns reviewer, updates Greenhouse |
| "review PR 15" | Reviews against acceptance criteria, posts approve/request-changes (doesn't merge) |
| "merge it" | Author squash merges their approved PR, cleans up, updates Greenhouse |
| "set me up" / "here's my CLI token" | Stores your personal token so skills act as you |
| "break this into tickets" | Plans and creates the full breakdown |
| "replan the auth epic" | Adjusts the plan based on learnings |
| "what's in flight?" | Shows the full dashboard |
| "fix the review comments" | Reads feedback, implements fixes, re-requests review |
| "run a health check" | Verifies branches, build, Greenhouse state, GitHub sync |

---

## How It All Connects

```
Greenhouse Ticket (with acceptance criteria)
  ↓ work-ticket (interactive or autonomous)
Branch (off the integration branch — dev if it exists, else main)
  ↓ write code + tests
PR ("Implements RG-42", reviewed, CI passing)
  ↓ review-pr (review → approve/request-changes verdict) → merge-pr (author squashes into the integration branch)
  ↓ release (opens the integration → main promotion PR when the repo uses one; tags main)
GitHub Release + git tag
```

Every link is maintained by a skill. `open-pr`'s ticket gate stops a PR without a ticket, and `review-pr` runs the compliance check on tickets tagged `soc2`, `iec_62304`, `hipaa` or `pii`.

---

## Skills

### Getting Work Done

| Skill | What it does |
|-------|-------------|
| **work-ticket** | Pick up a ticket — asks whether to work interactively or autonomously based on ticket readiness |
| **fix-review-feedback** | Read review comments, implement fixes, re-request review |
| **open-pr** | Push current branch, create PR, assign reviewer, update Greenhouse |
| **send-for-review** | Make a no-PR ticket a teammate's move — sets the reviewer, which the board, kanban and table show as `you → them` and Slack posts as a handoff |

### Planning

| Skill | What it does |
|-------|-------------|
| **create-ticket** | Break a feature into Greenhouse tickets; also handles replanning when requirements change |
| **tend-ticket** | Expand acceptance criteria, score complexity, make ticket AI-ready |
| **sow-feedback** | Digest a brainstorm note into created/updated tickets — Raw feedback becomes Planted work |

### Review & Merge

| Skill | What it does |
|-------|-------------|
| **review-pr** | Review a PR and post an approve/request-changes verdict (no merge); `--self` checks your own branch first |
| **merge-pr** | Author lands their own approved PR: squash merge, cleanup, harvest |

### Onboarding

| Skill | What it does |
|-------|-------------|
| **setup** | Store your personal CLI token (from Profile → CLI Access) — one-time onboarding |

### Status & Ops

| Skill | What it does |
|-------|-------------|
| **dashboard** | What's in flight across all projects |
| **health-check** | Branch and worktree cleanup, integration-branch build, Greenhouse↔GitHub sync verification |
| **release** | Generate notes from harvested tickets, open the promotion PR (`release_flow: promotion-pr`), tag, and watch what the tag fires |

### Parallel Agents

User-invoked only. See [Parallel agents](#parallel-agents-optional) for setup.

| Skill | What it does |
|-------|-------------|
| **loop-work** | Claim the next tended ticket assigned to you and implement it autonomously in its own worktree |
| **loop-fix** | Address review feedback on one of your PRs in its ticket's worktree |
| **loop-review** | One read-only review tick: review PRs waiting on you at a head you haven't reviewed |
| **loop-merge** | One merge tick: apply an approved PR's merge conditions, wait for every CI job, land it |

---

## Parallel agents (optional)

Run several Claude Code chats on one project at once — some implementing tickets, some fixing review feedback, one reviewing, one merging — without them fighting over tickets, your checkout, the local database or the CPU. Each chat works in its own git worktree, and the shared things go through **`gh-coord`**, a small coordinator in the plugin's `bin/`. **`gh-dash`** is the local dashboard that shows every chat and starts new ones, and it's the one process that tells Greenhouse what this machine is running: the team sees it on the **Agents** page, on each ticket, and as an orange badge on the corkboard. Nothing runs in the cloud — the chats run on your machine.

### Set up once per project

Add the keys your project needs to the `greenhouse` block in CLAUDE.md (only `project_key` is required, and it's already there):

```greenhouse
local_stack: myapp                      # the project_id in supabase/config.toml; leave out when there's no local database
db_commands: [pnpm db:seed, pnpm test:db, "supabase *"]   # need the DB lock
heavy_commands: [pnpm build, pnpm typecheck]               # take a heavy slot
```

Without `local_stack` the DB lock turns off and the chats skip it.

### Set up once per machine

1. **Trust the repo for the CLI and approve its MCP servers.** Run `claude` once in a terminal in the main checkout and accept the prompts. A chat started without anyone watching otherwise stops at that dialog (gh-dash flags it as *stuck at startup*).
2. **Phone access to your chats (recommended).** Turn on **Enable Remote Control for all sessions** (VS Code: the command menu's Settings; CLI: `/config`, or `"remoteControlAtStartup": true` in `~/.claude/settings.json`) and **Push when actions required** in `/config`, then sign in to the Claude app. Every chat then shows in the app's Code tab, and permission prompts and questions buzz your phone and can be answered there. On a Team plan an org Owner first enables Remote Control in claude.ai's Claude Code admin settings. Greenhouse never carries your chats' questions or answers — Remote Control does.
3. **Optional env vars:** `GREENHOUSE_HEAVY_SLOTS` (default 1; 2 on a big machine), `GREENHOUSE_MACHINE` (default: the hostname), `GREENHOUSE_DASH_PORT` (default 7777, the next free port when taken), `GREENHOUSE_TERMINAL=iterm` (default: Terminal), `GREENHOUSE_AGENTS_DIR` (default `~/.greenhouse/agents/<project_key>`), `GREENHOUSE_PLUGIN_DIR` (a plugin checkout that terminal and background starts load with `--plugin-dir` — for trying plugin changes before a release; VS Code starts can't pass it).

### Start the dashboard

From any Claude Code chat in the repo, type `! gh-dash --detach --open` (the plugin's `bin/` is on the chat's PATH). It keeps running after the chat closes, and every loop skill starts it if it isn't running. It serves `http://127.0.0.1:7777` on this machine only.

**While gh-dash runs, Greenhouse can see this machine.** It reports only when something changes (there's no heartbeat), so a quiet machine costs nothing. Stop it and its chats end at once; if the machine sleeps or crashes, it shows offline after 10 minutes. A chat closed while it still holds a ticket ends an hour after its last `gh-coord` call (the dashboard offers the `gh-coord unclaim` line). Ticket status is unaffected either way, because the skills write that themselves. `gh-dash --report-preview` prints exactly what it sends: per chat its session id, name, ticket, role, what it's doing, needs-you, folder name and start time; per machine its heavy slots (how many, who holds each and what it runs), the DB lock and who's waiting, the stack and its start mode. Never transcript or prompt text, file contents, env values, CPU or memory, process lists or full paths. CPU, memory and busy/idle stay on the local page.

### Starting chats

Type a ticket number into the dashboard's `$ <key>-` prompt and click a button, or leave it empty to start a numbered `/loop 5m` review, fix or merge chat (`work next` picks the next tended ticket). A ticket's chat that's already open comes to the front instead of starting a second. Names never repeat within a day: loops count up (`<key>-review 1`, `2`, …), and a ticket's second chat of a kind gets a number (`<key>-<n> 2`, `<key>-<n> fix 2`), even when Claude Code shows no sign of the first. The **start in** switch picks how the chat opens:

| Mode | What you get |
|------|--------------|
| **terminal** (default on macOS) | A Terminal (or iTerm) window running `claude -n <name> --remote-control <name> "<command>"`: named, runs with no Enter, and shows in the Claude app |
| **background** | `claude --bg`: named, runs with no Enter, no window. `claude attach <name>` opens it |
| **vscode** | A VS Code tab with the command typed in. Press Enter once — the extension's link can't send it |

From Greenhouse, a ticket's start buttons (tend, work, review, fix, merge, right under its title on the corkboard pane and the kanban modal) queue a request that reaches your gh-dash at once. They show only while one of your machines is online. The request travels over Supabase Realtime, on a private topic only you can join, and starts in terminal (or background) mode. Without a Realtime connection gh-dash checks the queue every minute instead. Requests carry only a kind and a ticket — never free text — and expire after 10 minutes. **Open in VS Code** opens the command in VS Code on whichever machine you clicked it.

### Known limits

- gh-dash reads Claude Code internals that aren't a documented interface (`~/.claude/sessions`, transcript titles). After a Claude Code update it may show chats unnamed; it degrades rather than breaks.
- A queued start needs the machine awake and gh-dash running. Terminal mode is macOS only; elsewhere use background.
- Each running gh-dash holds one Supabase Realtime connection, which counts toward the plan's concurrent-connection limit.
- The DB lock is per project. Two projects that share local database ports are guarded only by `db-stack` reporting `other:<project>`.

---

## Epic Branch Workflow

Epics are opt-in: one exists only when you ask for it while planning. When a planned epic has 2+ tickets, `create-ticket` creates an epic branch (`epic/{id}-{slug}`). All ticket branches stem from it. Ticket PRs merge into the epic branch via `merge-pr`. When all tickets are done, `merge-pr` offers a final epic PR into the integration branch.

Without an epic — the normal case — branches go directly off the integration branch.

---

## Conventions

### Branches

```
{initials}/{ticket-id}-{short-description}
```
`dt/rg-42-password-reset`, `mb/rg-15-supabase-upgrade`

### Commits

```
{type}: {description} [{ticket-id}]
```
`feat: add password reset flow [RG-42]`

Types: `feat`, `fix`, `chore`, `refactor`, `test`, `docs`, `style`, `perf`, `ci`, `hotfix`

### Reviewer Assignment

Set by the size of the Team table in CLAUDE.md: no reviewer for a team of one, the other person for a team of two, and a question (with the ticket's reviewer as the default) on three or more. A reviewer you name — or "no reviewer" — always wins. See `skills/conventions` §Reviewer Rule.

### Quality Gate (runs before every PR)

```bash
pnpm install --frozen-lockfile
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

### Labels

Every ticket gets 2-5 labels from: `frontend`, `backend`, `api`, `database`, `auth`, `payments`, `testing`, `docs`, `devops`, `security`, `performance`, `accessibility`, `ux`, `rls`, `migration`, `webhook`, `email`, `analytics`

Skills add labels automatically based on what the code touches.

### Epics

Any 2+ related tickets get grouped under an epic. Skills create and link epics automatically.

---

## Ticket Lifecycle

```
Seeds → Sprouted → In Bloom → In Review → Harvest
                      ↑               ↓
                      └── Changes Requested
```

| Status | Set by |
|--------|--------|
| Seeds | `create-ticket` (default) |
| Sprouted | `tend-ticket` |
| In Bloom | `work-ticket` |
| In Review | `open-pr` |
| Changes Requested | `review-pr` |
| Harvest | `merge-pr` |

---

## Complexity Scoring

Every ticket gets a complexity score (1-64, powers of 2) that drives how Claude approaches the work. Scoring piggybacks on work already being done — no extra token cost. See [references/work-breakdown.md](references/work-breakdown.md) for the full scale and assessment fields.

Two Greenhouse properties track predicted vs actual. If they consistently diverge, your tending needs calibration.

---

## File Structure

```
plugin/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest
│   └── marketplace.json         # Marketplace catalog
├── skills/
│   ├── conventions/SKILL.md     # Shared conventions (background knowledge, not user-invokable)
│   ├── create-ticket/SKILL.md
│   ├── tend-ticket/SKILL.md
│   ├── sow-feedback/SKILL.md
│   ├── work-ticket/SKILL.md
│   ├── fix-review-feedback/SKILL.md
│   ├── open-pr/SKILL.md
│   ├── send-for-review/SKILL.md
│   ├── review-pr/SKILL.md
│   ├── merge-pr/SKILL.md
│   ├── setup/SKILL.md
│   ├── dashboard/SKILL.md
│   ├── health-check/SKILL.md
│   ├── release/SKILL.md
│   └── loop-{work,fix,review,merge}/SKILL.md  # Parallel agents (optional)
├── bin/                         # gh-jwt, gh-heartbeat, gh-coord, gh-dash
├── hooks/hooks.json             # Notification hook: marks a parallel-agent chat as needing you
├── tests/gh-coord.test.sh       # Coordinator smoke tests (run in CI)
├── references/                  # Tech stack, schemas, gates, conventions
├── templates/                   # PR, ticket, plan, release note templates
├── LICENSE                      # MIT
└── README.md
```

---

## Reference Docs

Deep-dive docs that skills load as needed:

| File | What's in it |
|------|-------------|
| `references/riverroot.md` | Tech stack defaults, architecture patterns, testing philosophy |
| `references/greenhouse-schema.md` | Greenhouse database schema (projects, epics, tickets, relations, comments, activity log) |
| `references/status-flows.md` | Valid status transitions for tickets and epics |
| `references/commit-conventions.md` | Commit message and branch naming rules |
| `references/work-breakdown.md` | Complexity scoring scale, assessment fields, sizing and splitting rules |
| `references/compliance-guide.md` | SOC 2 and IEC 62304 mapping |
| `references/ticket-gate.md` | No code without a ticket gate |
| `references/compliance-check.md` | No merge without the full traceability chain |

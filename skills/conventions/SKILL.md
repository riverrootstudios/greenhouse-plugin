---
description: RiverRoot Studios shared development conventions. Config loading, Greenhouse access patterns, branch naming, commit format, labeling philosophy, epic usage, traceability chain. Background knowledge for all RRS skills.
user-invokable: false
---

# RiverRoot Studios — Shared Conventions

Background knowledge used by all greenhouse plugin skills. Claude loads this automatically when relevant.

---

## Step 0: Sync Queue Replay

Before any skill's main logic, check for and replay `.claude/greenhouse-sync-queue.json` if the Greenhouse API is reachable. See [references/common-operations.md](../../references/common-operations.md) Sync Queue Replay for details.

---

## Config Loading

Project config is embedded directly in the project's `CLAUDE.md` (committed to git). No external config file needed — clone and go.

### Project identity (from CLAUDE.md)

Read the `greenhouse` fenced code block in CLAUDE.md:

````
```greenhouse
project_id: <uuid>
project_key: <KEY>
org_id: <uuid>
```
````

These are the only values stored explicitly. Everything else is derived at runtime:

| Value | Source |
|-------|--------|
| `repo` | `git remote get-url origin` → parse `owner/repo` |
| `default_branch` | `git symbolic-ref refs/remotes/origin/HEAD` or default `main` |
| `base` | [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch) — where ticket branches are cut and PRs target |
| `tech_stack` | Stack line in CLAUDE.md (informational) |
| `team_username` | `${GREENHOUSE_TEAM_USERNAME}` from `gh-jwt` — the value every acting-user write stores. See resolution below |
| display | `display_name` + `initials` from `org_avatar_directory` for your username. See resolution below |
| `team` | Team table in CLAUDE.md — see [Team Table](#team-table) |
| `assignee` | The user's choice at creation, as a Team-table Greenhouse value; `work-ticket` sets `${GREENHOUSE_TEAM_USERNAME}` on pickup when empty |
| `reviewer` | See [Reviewer Rule](#reviewer-rule) |
| `ticket_type` | Default: `feature` |
| `priority` | Default: `p2_medium` |
| `quality_gate` | Common Commands section in CLAUDE.md |

Optional keys in the `greenhouse` fence — absent means the default:

| Key | Values | Default | Read by |
|-----|--------|---------|---------|
| `integration_branch` | a branch name | `dev` if `origin/dev` exists, else `main` | [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch) |
| `release_flow` | `tag-only` \| `promotion-pr` | `tag-only` | [release](../release/SKILL.md) |
| `release_artifacts` | list, e.g. `[plugin-manifest]` | none | [release](../release/SKILL.md) Step 5.5 |

### Current user resolution

The acting user has **one** stored identity, and it comes from the token. What
you call them on screen comes from the Greenhouse directory. Neither comes from
GitHub or the Team table:

| | Identity — `${GREENHOUSE_TEAM_USERNAME}` | Display — directory row |
|---|---|---|
| Comes from | exported by `gh-jwt` off the token's own `team_username` claim | `org_avatar_directory`, the row whose `team_username` is yours |
| Used for | **every** value a skill writes as the acting user: `assignee` (self), `created_by`, `updated_by`, comment `author`, `p_actor`, `triaged_by`, `time_entries.owner`, `claude_usage_*.user_name` | branch initials (`initials`, lowercased), `display_name` in PR text and reports |
| Never | derived from a GitHub login, git config, or a Team-table name or initials | written to Greenhouse |

Write the variable itself — `"updated_by": "${GREENHOUSE_TEAM_USERNAME}"` — not a
placeholder like `{user}` or "current user" that invites a local lookup. Writes
that are Claude's own autonomous actions use `"claude"` instead (see
[greenhouse-api §updated_by Rule](../../references/greenhouse-api.md#updated_by-rule)).

**Legacy CLAUDE.md wording is superseded.** Many project CLAUDE.md files still
tell you to resolve the current user from your GitHub login — *"…and matching
the result against the GitHub column"* — above a `Name | Initials | GitHub |
Role` Team table. That instruction predates GH-98, and following it is what wrote
`robin`, `sk` and `tm` into attribution columns. Ignore it for anything written
to Greenhouse — the token decides what is stored — and leave the rewrite to
`/greenhouse:health-check`.

**Identity — `${GREENHOUSE_TEAM_USERNAME}`:**

```
1. eval "$(${CLAUDE_PLUGIN_ROOT}/bin/gh-jwt)" exports GREENHOUSE_TEAM_USERNAME
   from the token's team_username claim. Interpolate the variable directly.
2. If it is empty, the token carries no identity. STOP the identity-bound
   write — never substitute a locally-derived name — and say which case it is.
   Route on ${GREENHOUSE_USER_ID} FIRST, then on the RPC. The RPC alone cannot
   separate the first two cases: current_team_username() has no error path —
   it swallows a missing claim (EXCEPTION WHEN others → NULL) and returns NULL
   for an unclaimed profile, so both return the same NULL. org_role doesn't
   track user-binding either (it is api_key for both).
     • ${GREENHOUSE_USER_ID} empty — a legacy org key, not bound to a member.
       No RPC call needed. →
       "Your token carries no user identity — run /greenhouse:setup with a
        personal CLI token."
     • ${GREENHOUSE_USER_ID} set, POST /rest/v1/rpc/current_team_username
       returns null — an invited member who has never opened the web app, so
       the profile has no team_username yet. →
       "Your Greenhouse profile has no username yet — open Profile in the web
        app once, then re-run /greenhouse:setup."
     • ${GREENHOUSE_USER_ID} set, the RPC returns a name — the claim is absent
       from the token but present on the profile, so the token predates the
       claim. gh-jwt self-heals this (it re-authenticates when a token has
       user_id but no team_username), so seeing it means the export was read
       from a token captured before that check ran. →
       "Your cached session token predates this claim — re-run
        eval "$(${CLAUDE_PLUGIN_ROOT}/bin/gh-jwt)" to mint a fresh one."
```

**Display — one directory call:**

```bash
curl -sS -X POST "${GREENHOUSE_URL}/rest/v1/rpc/org_avatar_directory" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Content-Type: application/json" -d '{}' \
  | jq --arg u "${GREENHOUSE_TEAM_USERNAME}" \
      '.[] | select(.team_username == $u) | {display_name, initials: (.initials // "" | ascii_downcase)}'
```

- `initials` → branch names (`jo/gh-42-…`); `display_name` → PR text and report headers.
- If the RPC fails, has no row for you, or the row has no initials, use the first two letters of
  `${GREENHOUSE_TEAM_USERNAME}` as initials and the username as the display
  name, and **say so in the output** — *"Directory lookup failed — using `jo`
  from your username."*

Why identity travels in the token: a GitHub login, a Team-table name and
initials are all different strings from the team username for most people.
Each one that reached an attribution column split a person in two — Robin
rendered as `RQ` and `RO`, Sam as `sam`, `sk`, `Sam` and `skowalski` — and on
`time_entries.owner` it was a member-only 42501 (owners pass
`is_org_admin_or_owner()` with any value, so it never showed up in testing).

### Legacy fallback

If CLAUDE.md has no `greenhouse` code block, check for `greenhouse-config.json` at the project root. If found, use it but warn:

> "This project uses the legacy greenhouse-config.json. Run `/greenhouse:health-check` to migrate config into CLAUDE.md."

### Connecting to Greenhouse

Three values are needed. Two are non-secret and **ship with the plugin**:

- `GREENHOUSE_URL` — Supabase project URL
- `GREENHOUSE_PUBLIC_KEY` — Supabase publishable/anon key (public by design; RLS protects data)

The third is the secret credential:

- `GREENHOUSE_API_KEY` — the developer's **personal** key (`ghk_live_*`), exchanged for a short-lived JWT via the `authenticate_key()` RPC.

[`gh-jwt`](../../bin/gh-jwt) resolves each value from the first source that has it:

1. **Environment variable** — wins, for overrides and one-shot org-switching
2. **`~/.greenhouse/config`** — written by [`/greenhouse:setup`](../setup/SKILL.md) (holds the personal API key), mode 600
3. **Plugin-shipped `config/defaults`** — `GREENHOUSE_URL` + `GREENHOUSE_PUBLIC_KEY` only

So onboarding is just `/greenhouse:setup` with a personal CLI token (generated in the web app under Profile → CLI Access) — **no shell-profile edits, no PATH setup, no repo clone.** See [references/greenhouse-api.md](../../references/greenhouse-api.md) for the underlying auth flow.

Skills invoke the helpers by absolute plugin path via the `CLAUDE_PLUGIN_ROOT` variable Claude Code substitutes at runtime:

- `eval "$(${CLAUDE_PLUGIN_ROOT}/bin/gh-jwt)"` — caches the token at `~/.greenhouse/jwt`, auto-refreshes within 60s of expiry, exports `GREENHOUSE_JWT`.
- `${CLAUDE_PLUGIN_ROOT}/bin/gh-heartbeat` — pings `tick_session_timer` to keep any running time-tracking entry alive. Idempotent, no-op when nothing is running.

---

## Greenhouse Access

For API details (headers, URL construction, operation mapping, UUID resolution, error handling), see [references/greenhouse-api.md](../../references/greenhouse-api.md).

---

## Greenhouse Data Integrity

All Greenhouse mutations must go through the appropriate skill. Never call Greenhouse API directly to create or update records outside of a skill invocation.

| Action | Required Skill |
|--------|---------------|
| Create ticket(s) | `/greenhouse:create-ticket` |
| Expand/score a ticket | `/greenhouse:tend-ticket` |
| Sow brainstorm feedback into tickets | `/greenhouse:sow-feedback` |
| Start or implement a ticket | `/greenhouse:work-ticket` |
| Open a PR | `/greenhouse:open-pr` |
| Send a no-PR ticket for review | `/greenhouse:send-for-review` |
| Review a PR (verdict only) | `/greenhouse:review-pr` |
| Merge an approved PR (author) | `/greenhouse:merge-pr` |
| Clean up / sync check | `/greenhouse:health-check` |
| Tag a release | `/greenhouse:release` |

If the user asks to create a ticket, check the board, or update Greenhouse — route to the appropriate skill. Do not take shortcuts with raw API calls.

### Ad-hoc status changes require confirmation

A ticket/epic/project `status` PATCH **outside the scripted step of its matching skill** requires explicit user confirmation. Other team members may be relying on the current state, and silent status mutations have caused workflow disruptions for collaborators in the past.

**Scripted transitions are exempt** — those are the skill's contract:

| Skill | Scripted transition |
|-------|---------------------|
| `tend-ticket` | `seeds` → `sprouted` |
| `work-ticket` | `sprouted`/`seeds` → `in_bloom` |
| `open-pr` | `in_bloom` → `in_review` |
| `review-pr` | `in_review` → `changes_requested` (request changes) |
| `merge-pr` | `in_review` → `harvest` (squash merge) |
| `fix-review-feedback` | `changes_requested` → `in_review` |
| `release` | `harvest` → release-tagged variants |

**Anything else requires the user to say so explicitly.** Rolling a ticket back to a previous state, jumping it forward without going through the skill, "tidying" a stuck ticket, or fixing what looks like a wrong status — all of these need a user go-ahead first. If a status looks wrong, surface it ("`{TICKET-ID}` is `in_review` but the PR is closed — should I move it to `weeded`?") and wait for an answer. Do not fix silently.

---

## Capturing user corrections as durable rules

When the user corrects a convention, assumption, scope decision, or workflow preference **that is likely to recur**, ask once before continuing:

> "Should I persist this as a durable rule? Options: auto-memory (`feedback_*.md`), `plugin/references/engineering-conventions.md`, this project's `CLAUDE.md`, or skip."

This applies when the correction is general (version selection rules, test discipline, status hygiene, naming preferences, library choices) — not when it's a one-off context-specific fix (typos, this-PR-only choices, judgment calls that depend on the specific code being touched).

The right destination depends on scope:

| Destination | When |
|-------------|------|
| Auto-memory (`feedback_*.md`) | User-specific preference or working style — applies across all projects but is about how to collaborate with this user |
| `plugin/references/engineering-conventions.md` | General engineering rule that applies to any project using the Greenhouse plugin |
| Project `CLAUDE.md` | Rule that applies only inside this specific repo (e.g., a Greenhouse-only workflow detail) |
| Skip | One-off, or unclear whether it'll recur |

Don't write the memory or open the file unless the user confirms. The point is to *ask*, not to silently persist.

---

## Dependency Fixes

When a bug traces to a third-party dependency, prefer the least invasive fix:

1. **Config or usage change first** — adjust how we call the package, pin/upgrade to a version where it's fixed, or work around it in our own code.
2. **Never patch a published package without asking.** Do not edit `node_modules`, commit a `pnpm patch` / `patch-package` diff, or vendor a modified copy on your own judgment. These are invisible in review, break on reinstall, and hide the real problem. Surface the situation and the options, and let the user decide.
3. If a patch really is the right call, the user says so explicitly — then document why in the PR.

---

## Git Access

- `gh` CLI for GitHub operations (PRs, reviews, checks)
- Standard `git` for local operations (branch, commit, push)

---

## Ticket ID Format

`{PROJECT_KEY}-{NUMBER}` (e.g., `GH-42`). The project key is read from the `greenhouse` config block in CLAUDE.md. Numbers are auto-generated atomically by the `create_ticket` RPC function.

---

## Commit & Push Rules

- Commit format: `{type}: {description} [{ticket-id}]` — see [references/commit-conventions.md](../../references/commit-conventions.md) for full details
- Branch naming: `{initials}/{ticket-id-lowercase}-{short-description}`, initials from the directory (see [Current user resolution](#current-user-resolution)) — see [references/commit-conventions.md](../../references/commit-conventions.md)
- Never commit or push without the user's go-ahead (except `/greenhouse:open-pr` which is explicitly a commit+push+PR workflow)
- Batch related changes into a single commit
- Ticket PRs squash-merge into the resolved base; `main` takes merge commits from the integration branch at release

---

## Team Table

The project CLAUDE.md Team table says **who can be picked** as assignee or
reviewer. Greenhouse decides what gets stored.

```
| Greenhouse | GitHub    |
| ---------- | --------- |
| sam        | skowalski |
| jo         | jo-reyes  |
```

- **Greenhouse** — the team username. The only value written to `assignee` / `reviewer`.
- **GitHub** — the login. Used only for `gh pr create --reviewer` / the `requested_reviewers` API; Greenhouse stores no GitHub login.

Read columns **by header name**, never by position, and map between them by
finding the row on one column and reading the other: a PR author's login →
their Greenhouse value, a chosen reviewer's Greenhouse value → their login.

**Legacy four-column table** (`Name | Initials | GitHub | Role`, pre-GH-98) —
still in many repos, and it must keep routing PRs. The GitHub column works as
is. It has no Greenhouse column, so bridge each row through the directory:
match its `Initials` (case-insensitive) against `org_avatar_directory.initials`;
exactly one match gives that row's `team_username`, anything else skips the row
with a warning. Never store a Name or Initials value. Say once per run that the
table is stale and `/greenhouse:health-check` rewrites it.

---

## Reviewer Rule

The one definition — skills reference this section instead of restating it.

```
candidates = Team-table rows whose Greenhouse value != the implementer
```

The implementer is `${GREENHOUSE_TEAM_USERNAME}` when you open the PR
(`open-pr`, and autonomous `work-ticket` settling it up front), and the
ticket's assignee when you're assigning work (`create-ticket`, and `review-pr`
creating a ticket for someone else's PR). A reviewer is never the person who
writes the code.

| Candidates | Reviewer | Question asked |
|---|---|---|
| None (a 1-row table) | `reviewer` stays null — the PR opens with no requested reviewer — and the skill warns: *"No reviewer candidate in the Team table — add a row (`/greenhouse:setup` prints yours)."* | no |
| Exactly one (a 2-row table) | That row | no |
| Several (3+ rows) | asked — the ticket's existing `reviewer` is offered as the default when it is among the candidates, then the other candidates, then "no reviewer". Never pick silently | yes |

Rules at every size:
- **Named in the session wins.** A reviewer — or "no reviewer" — the user already named ("jo reviews", "no reviewer on this one") is used as-is, with no question.
- **An implementer who isn't in the Team table** (an outside collaborator) → every row is a candidate; with two or more, ask — "the other person" is ambiguous.
- **"No reviewer" is always valid.** open-pr omits `--reviewer`, and the ticket's `reviewer` stays null.
- **Values.** Store the chosen row's **Greenhouse** value as `reviewer` (`"sam"`, `"jo"`); pass the same row's **GitHub** value to `--reviewer`. A row with no GitHub value means the PR is created without a GitHub reviewer, with a warning.

Skills that resolve a reviewer: `open-pr` (at PR creation), `work-ticket` (autonomous mode asks up front, so the unattended run never stops), `create-ticket` (pre-fills the approval table when the rule yields exactly one candidate, leaves it blank when it would ask), `send-for-review` (its own picker, same default). `fix-review-feedback` doesn't resolve one — it re-requests whoever submitted the review.

---

## Labeling Philosophy

Every ticket should have **2-5 labels**. Labels are assigned once during `create-ticket` or `tend-ticket` — downstream skills do not re-enrich labels. Labels stay unless the ticket's scope changes. See [references/labeling-guide.md](../../references/labeling-guide.md) for the full signal-to-label mapping.

---

## Epic Usage

**Epics are opt-in.** An epic exists only when planning explicitly calls for one — the user asked for it in the conversation. By default a ticket has no epic (`epic_id` null), however many related tickets a breakdown produces. Skills don't go looking for an epic to link, suggest one, or create one on their own.

When the user does ask for one, epics provide:
- A single place to see progress on a feature (via the `epic_progress` view)
- Context for reviewers ("this ticket is part of the auth overhaul")
- Compliance traceability (requirement → epic → tickets → code), with source docs on the epic's `planning_refs`

Without an epic, source-doc provenance goes in a **Source** section of the ticket description (see [create-ticket](../create-ticket/SKILL.md) Step 1).

Existing epic links stay as they are — this is forward-only.

---

## Epic Branch Lifecycle

When `create-ticket` creates a planned epic with 2+ tickets, it creates a shared git branch that all ticket branches stem from.

**Naming:** `epic/{epic-display-id}-{slug}` (e.g. `epic/gh-5-plugin-audit`)

**Created by:** `create-ticket` immediately after the epic record, pushed to remote.

**Ticket branches:** `work-ticket` branches off the epic branch (not the integration branch) when the ticket belongs to an epic with `epic_branch` set.

**PRs:** Each ticket PR merges into the epic branch (not the integration branch) via `merge-pr`.

**Completion:** When all non-weeded tickets in the epic are harvested, `merge-pr` offers to create a final epic PR from the epic branch into the integration branch (rungs 4–5 of [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch)).

**Stored in:** `epics.epic_branch` (text column).

---

## PR Review Format

Reviews produce structured, unambiguous findings for AI-to-AI consumption. Every finding is tagged:

| Tag | Meaning | Gate Effect |
|-----|---------|-------------|
| `[REQUIRED]` | Must fix before merge. Includes bugs, security, unmet criteria, AND small cohesion fixes. If skipping it causes codebase drift, it's required. | Any code `[REQUIRED]` → request changes. When every remaining one is doc-like (docs, comments, copy), the reviewer may instead approve with them under `## Merge conditions` |
| `[NOTED]` | True FYI only — no action to take. Known tradeoffs, pre-existing issues outside the PR's scope. Rare. | Does not block merge |

**Every `[REQUIRED]` finding includes:** `File:` (exact location), `Issue:` (what's wrong), `Fix:` (concrete instruction).

**Gate follows the findings:** findings determine the outcome, not a separate recommendation — the one reviewer choice is approve-with-merge-conditions when only doc-like `[REQUIRED]` findings remain. The human is involved during the review for judgment calls (architecture, intent, scope expansion) — not after.

**`fix-review-feedback` consumes this format directly** — parses `[REQUIRED]` items and implements the `Fix:` instructions. `[NOTED]` items are skipped. Unstructured comments from human reviewers are escalated to the user for classification before acting.

---

## Traceability Chain

Every link maintained by skills — the normal path, with no epic:
```
Ticket (Greenhouse) → Ticket Branch (off {base}) → Code + Tests →
PR (GitHub, "Implements {TICKET-ID}") → Review →
Squash Merge into {base} ("{type}: {desc} [{ticket-id}]") → Ticket Harvest (Greenhouse) →
Release ({base} → main, git tag)
```

With an explicitly planned epic, an epic layer wraps the ticket: `Epic (Greenhouse) → Epic Branch (git) → …ticket chain, squashing into the epic branch… → Final Epic PR → {integration branch}`.

---

## Reference Loading Guide

| Reference | Load When |
|-----------|-----------|
| [greenhouse-api.md](../../references/greenhouse-api.md) | Any skill making Greenhouse API calls |
| [engineering-conventions.md](../../references/engineering-conventions.md) | Always during planning and self-review in work-ticket; during review in review-pr |
| [riverroot.md](../../references/riverroot.md) | During implementation in work-ticket; during review in review-pr |
| [pre-pr-checklist.md](../../references/pre-pr-checklist.md) | During self-review in work-ticket (Step 7); during evaluation in review-pr (Step 2) |
| [review-patterns.md](../../references/review-patterns.md) | During self-review in work-ticket (Step 7) and evaluation in review-pr (Step 2). **Two layers, both loaded:** the plugin file is the shared baseline, edited by hand in the greenhouse repo; the repo's own `.claude/review-patterns.md` holds project-specific patterns, captured automatically by fix-review-feedback (Step 8.5) |
| [work-breakdown.md](../../references/work-breakdown.md) | During scope discovery in work-ticket; during complexity scoring in tend-ticket and create-ticket |
| [commit-conventions.md](../../references/commit-conventions.md) | During commit/PR in open-pr, work-ticket, review-pr |
| [common-operations.md](../../references/common-operations.md) | Quality gate, blocker checks, session timer, sync queue replay |
| [greenhouse-schema.md](../../references/greenhouse-schema.md) | When modifying Greenhouse tables or understanding data model |
| [ticket-gate.md](../../references/ticket-gate.md) | In open-pr and work-ticket before implementation |
| [compliance-check.md](../../references/compliance-check.md) | In review-pr only for compliance-tagged tickets (soc2, iec_62304, hipaa, pii) |
| [labeling-guide.md](../../references/labeling-guide.md) | In create-ticket and tend-ticket for label assignment |
| [common-operations.md §Lifecycle Notifications](../../references/common-operations.md#lifecycle-notifications) | In sow-feedback when enqueuing update notifications; any time a skill is tempted to talk to Slack (it must not) |

---
description: Full consistency check — branch and worktree cleanup, integration-branch build, Greenhouse state, GitHub sync. Use when cleaning up after a merge, checking sync, looking for inconsistencies, or verifying the repo is in a clean state.
---

# Skill: Health Check

Full consistency check combining post-merge verification and cross-system sync. After the standard report, offers optional complexity scoring on recently merged tickets.

---

## Step 0a: Preflight

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

**Resolve `{base}`** — the integration branch, from rungs 4–5 of [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch) (fence `integration_branch`, else `dev` if it exists, else `main`). Merged ticket PRs land there, so that's the branch this skill compares against and builds.

**Record the starting branch** — health-check checks out `{base}` to verify the build (Step 3), so capture where the user was to restore it at the end (Step 7). Never leave the user on a branch they didn't start on.

```bash
START_BRANCH=$(git branch --show-current)
```

Also stash-guard: if `git status --porcelain` is non-empty, do NOT check out anything. Warn the user there are uncommitted changes and run health-check in read-only mode (skip Step 3's `git checkout {base}`; report build status as "skipped — uncommitted changes"). Switching branches with a dirty tree is how you lose work.

---

## Step 0b: CLAUDE.md Integrity Check

Before running other checks (which depend on config), verify the project's CLAUDE.md is complete and up-to-date. Compare against [templates/greenhouse/claude.md.template](../../templates/greenhouse/claude.md.template) for expected structure.

### Required sections

| Section | What to check |
|---------|---------------|
| **Greenhouse config block** | `greenhouse` fenced code block exists with valid `project_id` (UUID format), `project_key`, and `org_id` |
| **Onboarding line** | Greenhouse Integration section describes the `/greenhouse:setup` token flow — NOT a stale `Env vars: GREENHOUSE_URL, GREENHOUSE_PUBLIC_KEY, GREENHOUSE_API_KEY` bullet (old style) |
| **Team table** | Two-column `\| Greenhouse \| GitHub \|` table, at least one row, and every Greenhouse value exists in `org_avatar_directory` — see [Team table validation](#team-table-validation) |
| **Current user resolution** | Identity-bound writes are pointed at `${GREENHOUSE_TEAM_USERNAME}`. **Fails** as *Stale Team table (pre-GH-98)* if the file still carries the `gh api user --jq .login` resolve-the-current-user line or a four-column `Name \| Initials \| GitHub \| Role` table; also fails if it references legacy `greenhouse-config.json` |
| **Workflow table** | Intent → Skill routing table exists with the core skills: setup, create-ticket, tend-ticket, sow-feedback, work-ticket, open-pr, send-for-review, review-pr, merge-pr, fix-review-feedback, dashboard, sync-usage, health-check, release. A `rebase-update` row is stale (the skill was removed in GH-62) — offer to delete it |
| **Rules** | Enforcement rules present: "No code without a ticket", "always run `/greenhouse:open-pr`", "after merge run `/greenhouse:health-check`", "after review feedback run `/greenhouse:fix-review-feedback`" |
| **Commit convention** | Commit format section with `{type}: {description} [{TICKET-ID}]` pattern |
| **Git workflow** | Branch naming, squash merge, PR-only rules |
| **Plugin auto-install** | `.claude/settings.json` (committed) has an `extraKnownMarketplaces` entry named `riverroot` + `enabledPlugins` (`greenhouse@riverroot`). Don't check which repo the marketplace source points at — any source that serves the `riverroot` marketplace passes |

### Repair

For each missing or outdated section, offer to inject it from the template:
> "CLAUDE.md is missing {section}. Inject from template?"

**A stale Team table** gets its own prompt (see [Team table validation](#team-table-validation)), because the consequence isn't cosmetic — a repo whose CLAUDE.md still resolves the acting user from the Team table writes nicknames, initials and GitHub logins into attribution columns (Robin as `robin`, Sam as `sk`), which split one person into several avatars and make RLS reject non-owner members' time entries.

Only ever edit the CLAUDE.md of the repo the skill is running in. Other managed repos are surfaced as a list to visit, never edited remotely.

### Team table validation

One directory call covers every row:

```bash
curl -sS -X POST "${GREENHOUSE_URL}/rest/v1/rpc/org_avatar_directory" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Content-Type: application/json" -d '{}' | jq -c '[.[] | {team_username, display_name, initials}]'
```

A row is **offending** when its Greenhouse value isn't a `team_username` in that list, or when the whole table is the legacy four-column shape. For each one, name the row and its closest directory match — same `initials` (case-insensitive), else a `team_username` or `display_name` that starts with the row's value or name — or *"no directory match — ask them for their Greenhouse username (web app → Profile)"*:

```
Stale Team table (pre-GH-98) — {repo}/CLAUDE.md
  • line {n}: "Resolve the current user by running `gh api user --jq .login` …"
  • four-column table (Name | Initials | GitHub | Role)
  • row "Robin | rq | robertaquinn" → closest match: robinquinn
  • row "Theo | tm | tMarlow"       → closest match: theo
```

A two-column table whose values are all real usernames passes silently; a single bad value in one is reported the same way (`row "robin | robertaquinn" → closest match: robinquinn`).

Then offer the rewrite, showing the proposed section — the template's Team heading, the rows converted to `| {closest match} | {GitHub} |`, and the template's paragraph beneath:

> "Rewrite `{repo}/CLAUDE.md`'s Team section in the two-column format (and drop the `gh api user` line)? Rows with no directory match are left for you to fill in."

### Convert old-style project setup → new style

The repo-side of onboarding used to be handled by `init-project` (now removed). health-check owns the conversion. Detect and offer to fix:

1. **Legacy `greenhouse-config.json`** at the project root:
   - If CLAUDE.md already has the `greenhouse` config block → offer to delete the JSON file
   - If CLAUDE.md is missing the config block → read `greenhouse_project_id` and `project_key` from the JSON, inject into CLAUDE.md, then offer to delete the JSON
2. **Stale env-var onboarding** — if CLAUDE.md still lists the three `GREENHOUSE_*` env vars as required setup, replace that bullet with the `/greenhouse:setup` onboarding line from the template.
3. **Missing plugin auto-install** — if `.claude/settings.json` lacks the marketplace/enable block, offer to add the block from the plugin README's [Install for a whole project](../../README.md#install-for-a-whole-project) section (merging with any existing settings), so teammates get the plugin on folder-trust instead of a `--plugin-dir` alias.

Present these as a batch: *"This repo uses the old-style Greenhouse setup ({findings}). Convert to the new style (setup-token onboarding + auto-install)?"* — apply on confirmation. Credential migration for the developer's own machine (env vars → `~/.greenhouse/config`) is handled by `/greenhouse:setup`, not here.

### Greenhouse validation

Verify that the `project_id` in the config block matches an active project in Greenhouse:
```bash
curl -s "${GREENHOUSE_URL}/rest/v1/projects?id=eq.{project_id}&select=id,name,key" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}"
```
If no match → flag: "project_id in CLAUDE.md does not match any Greenhouse project."

---

## Step 1: Identify Recent Merges

```bash
gh pr list --state merged --json number,title,headRefName,mergedAt --limit 5
```

If a specific PR was mentioned, focus on that one. Otherwise, check all recent merges.

---

## Step 2: Branch Cleanup Verification

For each recently merged PR:

### Remote Branch
```bash
git ls-remote --heads origin {branch-name}
```
If still exists → auto-fix offer: `git push origin --delete {branch-name}`

### Local Branch
```bash
git branch --list {branch-name}
```
If still exists → auto-fix offer: `git branch -d {branch-name}`

### Orphaned Branches (all active remotes)
```bash
git branch -r --list 'origin/*' --no-merged origin/{base}
```
For each branch not merged to `{base}`: extract ticket ID → check Greenhouse status. If ticket is `harvest` or `weeded` → flag for deletion. If no matching ticket → flag as orphaned. (Squash merges leave the branch "unmerged" by ancestry, so the ticket status is what decides — not the git result alone.)

### Worktrees
```bash
git worktree prune
git worktree list --porcelain
```
`prune` drops records of worktrees whose directories are gone. Match each remaining worktree (other than the main checkout) to a ticket by its `branch`:
- ticket `harvest` or `weeded` → flag with a remove offer, per [common-operations §Worktrees](../../references/common-operations.md#worktrees) (confirm by path when it has uncommitted changes). A harvested ticket whose worktree is still registered is **not** stuck — offer to remove the worktree rather than reporting the ticket
- no matching ticket → report as orphaned, alongside orphaned branches

---

## Step 3: Integration Build Check

**Skip this step if the working tree was dirty (see Step 0a)** — report the build as "skipped — uncommitted changes" and do not switch branches.

Otherwise:
```bash
git checkout {base}
git pull origin {base}
```

Run the quality gate (see conventions). If any step fails:
> "`{base}` is broken. {failure details}. This needs immediate attention."

This leaves you on `{base}`; Step 7 restores your original branch.

---

## Step 4: Greenhouse State Verification

For each recently merged PR: extract ticket ID from PR description. Read them all in one call — `GET /rest/v1/tickets?display_id=in.({A},{B},...)&select=display_id,status,completed_at,pr_url,branch_name` — not one `get_ticket_context` per ticket. Verify:
- Status is `harvest`
- `completed_at` is set
- `pr_url` is set

For each active (non-harvest, non-weeded) ticket, verify status transitions make sense:
- `in_review` → should have a PR
- `in_bloom` → should have a branch
- `changes_requested` → should have a PR with changes requested

---

## Step 5: Cross-Reference GitHub ↔ Greenhouse

### Check 1: PRs Without Tickets
Parse each open PR description for `Implements {TICKET-ID}`. If missing → flag.

### Check 2: Tickets in `in_review` Without a PR
For each `in_review` ticket: verify `pr_url` is set and the PR exists and is open on GitHub. If PR is merged → ticket should be `harvest`. If PR is closed → ticket should return to `in_bloom`.

### Check 3: Merged PRs with Open Tickets
For each recently merged PR: linked ticket should be `harvest`.

### Check 4: Epic Status Consistency
Using `epic_progress` view, verify each epic's status matches its children:
- All non-weeded tickets `harvest` + epic not `complete` → flag
- Epic `planning` but a child is `in_bloom`/`in_review` → flag
- Epic `complete` but child ticket not `harvest`/`weeded` → flag

### Check 5: Stale In-Progress Tickets
For each `in_bloom` ticket with a branch: check for recent commits.
```bash
git log origin/{branch} --since="3 days ago" --oneline
```
If no recent commits → flag as stale.

---

## Step 6: Report & Offer Auto-Fixes

```
## Health Check — {date}

### CLAUDE.md Integrity
- Config block: {present / missing / repaired}
- Team table: {current / stale (pre-GH-98) — {N} rows flagged / missing}
- Workflow sections: {complete / {N} sections missing}
- Legacy config: {not found / migrated and deleted / still present}

### Recently Merged
| PR | Ticket | Status |
|----|--------|--------|
| #{number} | {ID}: {title} | Clean |
| #{number} | {ID}: {title} | Branch not deleted |

### Branch Status
- {N} merged branches cleaned up
- {N} stale branches remaining
- {N} worktrees: {removed | flagged — harvested/weeded | orphaned}

### Build ({base})
- lint: {passing/failing}
- typecheck: {passing/failing}
- test: {passing/failing}
- build: {passing/failing}

### Greenhouse Sync
- {N} tickets in correct state
- {N} tickets need status update

### Issues Found
- {issue}: {fix}
```

Offer to fix all found issues:
> "Found {N} issues. Fix all / fix some / skip?"

**Auto-fixable:**
- Delete stale branches (local + remote)
- Remove worktrees for `harvest` / `weeded` tickets (confirm by path if dirty)
- Update ticket status to match GitHub state — group the fixes by target status and send ONE `PATCH /rest/v1/tickets?display_id=in.({A},{B},...)&status=neq.{target}` per target status with `{"status": "{target}", "updated_by": "${GREENHOUSE_TEAM_USERNAME}"}` (add `completed_at` for `harvest`). Never one PATCH per ticket: each ticket write fires a realtime refetch on every open board
- Update epic status when children unanimously indicate the correct state

**Manual required:**
- PRs without ticket references (need ticket ID)
- Orphaned branches and worktrees without tickets (need investigation)
- Stale `in_bloom` tickets (need human decision)

---

## Step 7: Restore Starting Branch

Health-check must leave the user where it found them. If Step 3 checked out `{base}`, return to `START_BRANCH` (captured in Step 0a):

```bash
if [ -n "$START_BRANCH" ] && [ "$START_BRANCH" != "$(git branch --show-current)" ]; then
  if git show-ref --verify --quiet "refs/heads/$START_BRANCH"; then
    git checkout "$START_BRANCH"
  fi
fi
```

- If `START_BRANCH` still exists → check it out and confirm: *"Back on `{START_BRANCH}`."*
- If it was deleted during cleanup (its PR merged) → staying on `{base}` is correct; say so explicitly: *"`{START_BRANCH}` was merged and cleaned up, so you're on `{base}` now."*
- Never end silently on a branch the user didn't start on.

---

## Optional: Complexity Scoring

After the standard report, ask:
> "Want complexity scoring on recent merges? This compares predicted vs. actual complexity for tickets merged in the last 7 days."

If yes:

### Complexity Scoring (Recent Merges)

For each PR merged in the last 7 days:
1. Count files changed: `gh pr diff {number} --stat`
2. Assess blast radius: were changes isolated or cross-cutting?
3. Check `implementation_notes` for noted scope changes
4. Map to 1-64 scale using [references/work-breakdown.md](../../references/work-breakdown.md)
5. Compare to predicted complexity

```
### Complexity Review (last 7 days)
| PR | Ticket | Predicted | Actual | Divergence |
|----|--------|-----------|--------|------------|
| #15 | RG-40 | 4pt | 4pt | — |
| #14 | RG-38 | 8pt | 16pt | 2× — scope expanded during implementation |
```

If predicted and actual diverge by 2×+ consistently → note calibration opportunity.

---

## Error Handling

| Error | Action |
|-------|--------|
| `{base}` build fails | Report immediately — priority fix |
| Greenhouse API unreachable | Report git/GitHub findings, skip Greenhouse checks |
| No recent merges | "No PRs merged in the last 24 hours. Running sync check only." |
| Branch delete fails | Warn, continue — not critical |
| Uncommitted changes at start | Run read-only: skip `git checkout`/build, never switch branches |
| Started on a feature branch | Restore it in Step 7 — never leave the user on `{base}` unless their branch was merged away |

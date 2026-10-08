---
description: Cut a release — generate notes from harvested tickets, open the integration → main promotion PR when the repo uses one, tag, and watch the workflows the tag fires. Use when cutting a release, tagging a version, or shipping.
argument-hint: "[version]"
---

# Skill: Release

Gather done tickets, generate release notes, tag a release, and watch what the tag fires.

**Two flows**, chosen by `release_flow` in the repo's `greenhouse` fence (see [conventions §Config Loading](../conventions/SKILL.md#config-loading)):

| `release_flow` | What happens | For |
|----------------|--------------|-----|
| `tag-only` (default — key absent) | You're on `main`; the skill tags it | repos whose ticket PRs land on `main` |
| `promotion-pr` | The skill opens the `{integration} → main` promotion PR with the release notes and hands off; once a human merges it (merge commit), a second run tags `main` | repos with an integration branch — ticket PRs land on `dev`, `main` only takes merge commits |

`{integration}` is rungs 4–5 of [Resolve Base Branch](../../references/common-operations.md#resolve-base-branch) — fence `integration_branch`, else `dev` if it exists.

---

## Step 0: Preflight

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

---

## Prerequisites

- Clean working directory
- `tag-only`: on `main`, all PRs merged, CI passing
- `promotion-pr`: `{integration}` has the harvested work; CI passing on it

**Resuming `promotion-pr`:** look for the promotion PR first — `gh pr list --base main --head {integration} --state all --limit 1 --json number,state,mergedAt,title`.
- **Open** → report it and stop: *"Release PR #{n} is still open — merge it (merge commit), then run `/greenhouse:release` again to tag."*
- **Merged, and its title names a version with no tag yet** (`release: {version} — …`, `git tag -l {version}` empty) → this run tags: `git checkout main && git pull origin main`, keep that version, skip to Step 6.
- **Otherwise** (no promotion PR, or its version is already tagged, or an older hand-built roll-up with no version in its title) → check for a manifest bump PR from Step 5.5: `gh pr list --base {integration} --state all --search '"chore: bump plugin manifest" in:title' --limit 1 --json number,state,title`. Take `{version}` from its title (`chore: bump plugin manifest to {version}`); if `git tag -l {version}` already lists it, that bump belongs to a finished release — treat it as **None**.
  - **Open** → report it and stop: *"Manifest bump PR #{n} is still open — merge it, then run `/greenhouse:release` again."*
  - **Merged** → keep that version and regenerate the notes (Steps 2 and 4) without re-asking approval — the bump PR was opened under it. Skip Step 5.5 and continue at Step 5.7.
  - **None** → a new release; continue at Step 1.

---

## Step 1: Determine Version

**If version provided:**
- Validate semver format: `v{major}.{minor}.{patch}`
- Check it doesn't already exist: `git tag -l {version}`

**If no version (auto-increment):**
1. Get latest tag:
   ```bash
   git describe --tags --abbrev=0
   ```
2. Analyze changes since last tag to determine increment:
   - Any `feat:` commits → minor bump
   - Only `fix:` commits → patch bump
   - Breaking changes flagged → major bump
   - If no previous tag → `v0.1.0`

Present proposed version for confirmation:
> "Based on changes since {last-tag}, proposing {version} ({type} release). OK?"

---

## Step 2: Gather Harvest Tickets

Unreleased tickets are the ones named in commits since the last tag (there is no Release field). Parse those IDs from git first:

```bash
git log {last-tag}..HEAD --oneline                      # tag-only
git log {last-tag}..origin/{integration} --oneline      # promotion-pr
```

With no previous tag, use `origin/main..origin/{integration}` for promotion-pr (what the promotion PR would bring in).

Extract the `[{TICKET-ID}]` values from those commit subjects (dedupe), then fetch only those tickets — never every harvested ticket the project has ever had:

```bash
curl -s "${GREENHOUSE_URL}/rest/v1/tickets?project_id=eq.{id}&display_id=in.({A},{B},...)&select=display_id,title,type,status,assignee,pr_url,compliance_tags,labels&order=completed_at.desc" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}"
```

`status` is `harvest` for the release candidates; a commit-named ticket in any other status is worth a one-line warning (merged code, ticket never harvested). No IDs in the range → nothing to look up.

For each ticket, collect:
- Ticket ID, title, type
- Assignee
- PR URL
- Compliance tags
- Labels

---

## Step 3: Check for Issues

Before proceeding, verify:

### All Tickets Have Merged PRs
For each harvest ticket without a pr_url → flag:
> "Ticket {ID} is harvest but has no PR linked. Include in release anyway?"

### CI is Passing
```bash
gh run list --branch {main | integration} --limit 1 --json status,conclusion,headSha
```
`tag-only` checks `main`; `promotion-pr` checks `{integration}`. The run's `headSha` must be the branch tip (`git rev-parse origin/{branch}`), or CI is unverified.

### No Open Blockers
Check for tickets with blocking relations in the same epic — warn if critical work is blocked.

---

## Step 4: Generate Release Notes

Follow [templates/release-notes.md](../../templates/release-notes.md) format:

### Categorize by Type

Group tickets by their commit type:

| Category | Ticket Types |
|----------|-------------|
| Features | Feature |
| Bug Fixes | Bug, Hotfix |
| Improvements | Chore, Tech Debt, refactor, perf |
| Infrastructure | Infrastructure, ci |
| Security | Tickets with `security` label |

```markdown
# Release {version} — {project-name}

**Released:** {date}

---

## What's New

### Features
- Add password reset flow (RR-42)
- Implement subscription management (RR-38)

### Bug Fixes
- Fix duplicate subscription creation on retry (RR-39)

### Improvements
- Upgrade Supabase SDK to v2.49 (RR-41)

### Infrastructure
- Add preview deployment CI workflow (RR-40)

---

## Breaking Changes
{List any, or "None"}

## Migration Steps
{List any, or "None"}

---

## Tickets Included

| Ticket | Title | Type | Assignee |
|--------|-------|------|----------|
| RR-42 | Add password reset flow | Feature | dk |
| RR-39 | Fix duplicate subscription | Bug | mc |
...

---

## Contributors
- Dana Kim (dk)
- Max Chen (mc)
```

### Flag Special Items
- Breaking changes (from PR labels or commit messages)
- Migration requirements (from PR labels or ticket notes)
- Security fixes (highlight prominently)

---

## Step 5: Present for Approval

Show the release notes and ticket list, then list what the next step will fire and ask **once**. Read the triggers from `.github/workflows/*.yml` (`on:` blocks):

- `tag-only` — workflows triggered by pushing a tag (`push: tags`) and by publishing a release (`release:`)
- `promotion-pr` — workflows triggered by a `pull_request` into `main` (fire when the PR opens) and by a `push` to `main` (fire when a human merges it — e.g. a migrate job that applies migrations to production)

> "Releasing {version} with {N} tickets. {Tagging | Opening the promotion PR} will fire: {workflow — job, per line | nothing}. {promotion-pr: Merging it will then fire: {…}.} OK to go ahead?"

One yes covers the tag or the PR. Anything else pauses.

---

## Step 5.5: Bump Plugin Manifest (release artifact)

**Only when the fence has `release_artifacts: [plugin-manifest]`.** Without that key, skip this step — most repos have no plugin manifest.

`claude plugin update` is a no-op when `plugin/.claude-plugin/plugin.json`'s `version` field hasn't changed — even if upstream content has. Bump it to the release version so users running `claude plugin update` actually pick up the changes.

**`promotion-pr`:** if `plugin/.claude-plugin/plugin.json` on `origin/{integration}` already has `version` = `{version}` (without the leading `v`), the bump landed — skip to Step 5.7. Otherwise rulesets refuse direct pushes to `{integration}` and `main`, so the bump lands through its own PR first. Commit the bump below on `{initials}/release-{version}` cut from `origin/{integration}`, push it, and open it into `{integration}` (`chore: bump plugin manifest to {version}`). Hand off until it is merged, then continue to Step 5.7 — the promotion PR then carries the bump to `main`.

**`tag-only`:** commit the bump on `main` and push, as below.

```bash
# Strip the leading 'v' if present: v1.2.3 → 1.2.3
PLUGIN_VERSION="${version#v}"
node -e "
const fs = require('fs');
const f = 'plugin/.claude-plugin/plugin.json';
const j = JSON.parse(fs.readFileSync(f, 'utf8'));
j.version = '${PLUGIN_VERSION}';
fs.writeFileSync(f, JSON.stringify(j, null, 2) + '\n');
"
git add plugin/.claude-plugin/plugin.json
git commit -m "chore: bump plugin manifest to ${PLUGIN_VERSION}"
git push origin main   # tag-only; promotion-pr pushes its release branch instead
```

The release tag in Step 6 will then point at a commit that includes the version bump.

---

## Step 5.7: Open the Promotion PR (`promotion-pr` only)

```bash
gh pr create --base main --head {integration} \
  --title "release: {version} — roll {integration} into main" \
  --body "{release notes from Step 4}"
```

Then hand off — this skill doesn't merge it:

> "Release PR #{n} is open ({integration} → main). Merge it with a **merge commit**, not a squash — `main`'s ruleset only takes merge commits, and a squash would disconnect `main` from `{integration}`'s history. Then run `/greenhouse:release` again to tag {version}."

Stop. The next run resumes from the Prerequisites check and tags.

---

## Step 6: Create Git Tag & GitHub Release

On approval (`tag-only`), or on the resuming run after the promotion PR merged (`promotion-pr`, on an up-to-date `main`):

```bash
git tag -a {version} -m "Release {version}"
git push origin {version}
```

Create GitHub release:
```bash
gh release create {version} \
  --title "{version}" \
  --notes "{release-notes-content}" \
  --latest
```

---

## Step 6.5: Watch What the Tag Fired

Don't stop at "release published". List the runs the tag push started and watch each one:

```bash
gh run list --event push --branch {version} --json databaseId,name,status --limit 20
gh run watch {databaseId} --exit-status
```

Report each run's outcome. No runs → say so: *"The tag fired no workflows."* A failed run goes at the top of the Step 7 output, with its URL.

---

## Step 7: Output

```
## Release {version} Published

**GitHub:** {release-url}
**Tag:** {version}
**Commit:** {sha}
**Tickets:** {count}
**Workflows fired:** {name — ✅ success | ❌ failure {url}, per line | none}

### Summary
- {N} features
- {N} bug fixes
- {N} improvements
- {N} infrastructure changes

### Greenhouse
- Queried {N} harvested tickets from Greenhouse

### Next Steps
- Monitor deployment
- Verify in production
- Start next sprint/epic
```

---

## Error Handling

| Error | Action |
|-------|--------|
| Tag already exists | Suggest different version |
| No unreleased harvest tickets | *"No unreleased harvest tickets. Nothing to release."* |
| CI failing (or unverified) on the release branch | Block release until CI passes on the tip |
| Promotion PR still open | Report it and stop — a human merges it (merge commit) |
| Manifest-bump PR not merged (`promotion-pr`) | Hand off until it lands; don't open the promotion PR without the bump |
| A workflow the tag fired fails | Report it first in the output with its URL — the tag stays; fix forward |
| Greenhouse API unreachable | Create git tag and GitHub release, log TODO for Greenhouse |

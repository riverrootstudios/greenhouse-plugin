---
description: Connect the Greenhouse plugin using your personal CLI token. Stores the token in ~/.greenhouse/config so every skill authenticates as you — no shell env vars. Use when onboarding onto Greenhouse, setting up the plugin, or after generating a CLI token.
argument-hint: "[cli-token]"
---

# Skill: Setup

One-time onboarding. Stores your personal Greenhouse CLI token locally so every
other skill authenticates as *you*. No environment variables to edit, no repo to
clone.

**Where the token comes from:** sign into the Greenhouse web app and go to
**Profile → CLI Access → Generate CLI token**. It's a `ghk_live_…` key bound to
your account and scoped to the projects you can access (like a GitHub personal
access token). Prerequisites the user already has by this point: Claude Code with
this plugin loaded, and `gh auth login`.

---

## Step 0: Detect existing / old-style setup

Check what's already in place before doing anything:

```bash
[ -f "${HOME}/.greenhouse/config" ] && echo "config present" || echo "no config"
printf 'env GREENHOUSE_API_KEY: %s\n' "${GREENHOUSE_API_KEY:+set (from shell)}"
```

- **Already new-style** (`~/.greenhouse/config` exists, no stray env override) → this is a re-run. Ask whether they want to replace the stored token (e.g. rotating); if not, skip to Step 3 (verify) and report.
- **Old-style** (`GREENHOUSE_API_KEY` exported in the shell — the pre-migration setup — and no `~/.greenhouse/config`) → offer to migrate. Two paths:
  - **Recommended — get a personal token.** The old value is often a *shared org key* with no user identity. Point them to **Profile → CLI Access** to generate a personal `ghk_live_` token, then continue at Step 1. This is what makes their Greenhouse activity attributable to them.
  - **Quick migrate as-is.** If they'd rather not switch right now, copy the existing env value into `~/.greenhouse/config` (Step 2) for continuity. Note it keeps whatever identity/scope the old key had.
- **Fresh machine** (neither) → continue to Step 1.

### Old-style cleanup (guidance only — do NOT edit their dotfiles)

If old-style config is found, tell the user which lines to remove from their shell profile (`~/.zshrc` / `~/.bashrc`) once setup succeeds — show them the lines, let them delete them:

- `export GREENHOUSE_URL=…`, `export GREENHOUSE_PUBLIC_KEY=…`, `export GREENHOUSE_API_KEY=…` (URL + public key now ship with the plugin; the API key lives in `~/.greenhouse/config`)
- any `export PATH="…/greenhouse/plugin/bin:$PATH"` line (skills call `${CLAUDE_PLUGIN_ROOT}/bin` directly)
- any `alias claude='claude --plugin-dir …'` (the plugin auto-installs from the committed `.claude/settings.json`)

**Important:** a lingering `export GREENHOUSE_API_KEY` in the shell *overrides* `~/.greenhouse/config`, so if they don't remove it the old key keeps winning. Call this out explicitly.

Repo-level conversion (legacy `greenhouse-config.json`, missing `.claude/settings.json`, stale CLAUDE.md env-var bullet) is **not** this skill's job — that's `/greenhouse:health-check`. Mention it if you spot a `greenhouse-config.json` in the repo.

---

## Step 1: Get the token

If a token was passed as an argument, use it. Otherwise ask:

> "Paste your Greenhouse CLI token (starts with `ghk_live_`). Generate one in the
> web app under **Profile → CLI Access**. Not signed in yet? Open your invite
> email and click **Activate & Sign In** first."

Trim whitespace. It should start with `ghk_live_`. If it doesn't look like a key,
stop and re-ask — don't write anything.

---

## Step 2: Store the token

Write it to `~/.greenhouse/config` (mode 600). `gh-jwt` reads this file, so no shell
profile edits are needed:

```bash
mkdir -p "${HOME}/.greenhouse"
umask 177
printf 'GREENHOUSE_API_KEY=%s\n' "<token>" > "${HOME}/.greenhouse/config"
chmod 600 "${HOME}/.greenhouse/config"
```

Never echo the token back to the user or into the transcript.

---

## Step 3: Verify end-to-end

Confirm the token authenticates and report who the user is. Clear any stale cached
JWT first so the new token is actually exercised:

```bash
rm -f "${HOME}/.greenhouse/jwt"
eval "$(${CLAUDE_PLUGIN_ROOT}/bin/gh-jwt)"   # mints a JWT from the new token
gh api user --jq .login                       # confirms GitHub identity
```

If `gh-jwt` fails, the token is wrong or revoked — tell the user to generate a fresh
one under **Profile → CLI Access** and re-run. Do a trivial authenticated read to
prove scope:

```bash
curl -sS "${GREENHOUSE_URL}/rest/v1/projects?select=key,name&limit=5" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}"
```

**Record the GitHub login.** When `gh api user` returned a login, save it to the
user's profile so the web shows their PRs as them (initials, "your move") instead
of a GitHub photo (GH-109). The RPC writes only the caller's own row:

```bash
curl -sS -X POST "${GREENHOUSE_URL}/rest/v1/rpc/set_my_github_login" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Content-Type: application/json" \
  -d "{\"p_login\": \"{gh login}\"}"
```

A non-2xx response is a one-line warning in the report ("Couldn't save your GitHub
login to Greenhouse: {message}"), never a setup failure — `23505` means another
profile already holds that login, so name it and suggest asking an admin. No gh
login → skip; the Step 4 warning covers it.

---

## Step 4: Report

```
You're set up on Greenhouse.

- Greenhouse username: {GREENHOUSE_TEAM_USERNAME}
- Signed in to GitHub as: {gh login}
- Projects you can see: {list, or "none yet — ask an admin to grant access"}
- Credential stored: ~/.greenhouse/config (chmod 600)

Your commits and Greenhouse activity are now attributed to you. Try `/greenhouse:dashboard`.
```

**Team-table row.** If the current repo's CLAUDE.md has a Team table, look for a
row whose **Greenhouse** value is exactly `${GREENHOUSE_TEAM_USERNAME}` (see
[conventions §Team Table](../conventions/SKILL.md#team-table)). If there is none,
print the exact row to add, so PRs can be routed to you for review:

```
This repo's Team table has no row for you. Add this line to its CLAUDE.md:

| {GREENHOUSE_TEAM_USERNAME} | {gh login} |
```

If the table is still the legacy four-column shape (`Name | Initials | GitHub |
Role`), say so, print the same two-column row, and point at
`/greenhouse:health-check` to rewrite the table. Only print — this skill never
edits CLAUDE.md. No Team table (not a Greenhouse repo) → skip.

If `${GREENHOUSE_TEAM_USERNAME}` is empty, the token carries no identity — report
it with the messages in [conventions §Current user resolution](../conventions/SKILL.md#current-user-resolution)
instead of a row.

If `gh api user` returned nothing, warn: "You're not signed in to GitHub — run
`gh auth login` so your PRs and reviews are attributed correctly." The row then
reads `| {GREENHOUSE_TEAM_USERNAME} | {your GitHub login} |`.

---

## Notes

- **Re-running is safe.** Pasting a new token overwrites `~/.greenhouse/config`.
- **Rotating/revoking:** generate a new token in the web app (Profile → CLI Access)
  and re-run this skill; revoke old ones from the org's API Keys settings.
- **Switching orgs:** set `GREENHOUSE_API_KEY` in the shell for a one-off session —
  an env var always overrides `~/.greenhouse/config`.
- **This skill never touches Greenhouse state** and never needs a ticket.

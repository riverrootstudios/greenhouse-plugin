---
description: Sync Claude Code token usage to Greenhouse. Use when syncing usage, checking token counts, updating Claude usage, or after completing work.
---

# Skill: Sync Usage

Capture Claude Code token usage from local logs via `ccusage` and push daily + project breakdowns to Greenhouse.

This skill should also be run as a follow-up step after committing, pushing, or opening a PR to keep usage data current.

---

## Prerequisites

- `ccusage` must be installed: `npm install -g ccusage` or use `npx ccusage`
- Greenhouse env vars: `GREENHOUSE_URL`, `GREENHOUSE_PUBLIC_KEY`, `GREENHOUSE_API_KEY`

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

## Step 0.1: Resolve Current User + Org

`user_name` on every upsert below is `${GREENHOUSE_TEAM_USERNAME}`, exported by the Step 0 `gh-jwt` eval from the token's own claims. It works for every org member, including external collaborators who are not in the CLAUDE.md Team table — and unlike a locally-derived name, it can't disagree with the identity RLS checks against (see [common-operations §identity on writes](../../references/common-operations.md#identity-on-writes)).

If it's empty, the token carries no identity — stop rather than attributing rows to a guess:

- no user binding (a legacy org key) → *"Your token carries no user identity — run `/greenhouse:setup` with a personal CLI token."*
- user-bound, but the profile has no `team_username` yet → *"Your Greenhouse profile has no username yet — open Profile in the web app once, then re-run `/greenhouse:setup`."*

`POST /rest/v1/rpc/current_team_username` (empty JSON body, standard headers) distinguishes the two: a null response on a user-bound token means the second case. Usage rows must always be attributed to the caller's own username; RLS rejects writes for anyone else's.

`org_id` is required by RLS on `claude_usage_daily` and `claude_usage_projects` — direct PostgREST inserts otherwise hit 42501. The `gh-jwt` eval in Step 0 already exports it as `${GREENHOUSE_ORG_ID}`; use that directly rather than decoding the token again (see [common-operations §org_id on writes](../../references/common-operations.md#org_id-on-writes)).

---

## Step 1: Push Daily Usage

`ccusage daily --json` shape (as of 2026-05): each row is `{ period, agent, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalCost, modelsUsed: string[] }`. The `agent` field replaces the old `date` field and now also emits per-agent rows alongside an `agent: 'all'` rollup — filter to `'all'` to avoid N duplicate inserts per day. `modelBreakdowns` (object array with per-model token counts and cost) is gone; `modelsUsed` is just a name array.

**Window, not history.** Past days don't change, so re-upserting them is pure egress. Upsert only the last 2 days (today + yesterday), widened back to the day before the last sync when that is older — a week without syncing still gets the whole week. The last sync time lives in `~/.greenhouse/last-usage-sync`; with no file yet (first run) the window is 30 days, which is about all Claude Code keeps on disk anyway.

`session_count` is derived, not assumed: the number of distinct session JSONL files under `~/.claude/projects` with at least one entry on that local day. Only files written since the window opened are read.

```bash
mkdir -p ~/.greenhouse && date -u +%Y-%m-%dT%H:%M:%SZ > ~/.greenhouse/last-usage-sync.pending
node -e "
const fs = require('fs'), path = require('path'), os = require('os');
const { execSync } = require('child_process');
const user = '${GREENHOUSE_TEAM_USERNAME}';
const org  = '${GREENHOUSE_ORG_ID}';
const DAY = 86400000;
const pad = n => String(n).padStart(2, '0');
const localDay = t => { const d = new Date(t); return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); };

let last = NaN;
try { last = Date.parse(fs.readFileSync(path.join(os.homedir(), '.greenhouse', 'last-usage-sync'), 'utf8').trim()); } catch {}
const since = localDay(Math.min(Date.now() - DAY, isNaN(last) ? Date.now() - 30 * DAY : last - DAY));
const sinceMs = new Date(since + 'T00:00:00').getTime(); // local midnight

const d = JSON.parse(execSync('npx ccusage@latest daily --json --since ' + since + ' 2>/dev/null',
  { maxBuffer: 64 * 1024 * 1024 }).toString());
const rows = (d.daily || []).filter(r => r.agent === 'all' && r.period >= since);

// Distinct session files active per local day, from files touched inside the window.
const sessionsByDay = new Map();
const root = path.join(os.homedir(), '.claude', 'projects');
for (const dir of fs.existsSync(root) ? fs.readdirSync(root) : []) {
  let files; try { files = fs.readdirSync(path.join(root, dir)); } catch { continue; }
  for (const f of files) {
    if (!f.endsWith('.jsonl')) continue;
    const fp = path.join(root, dir, f);
    if (fs.statSync(fp).mtimeMs < sinceMs) continue;
    const days = new Set();
    for (const m of fs.readFileSync(fp, 'utf8').matchAll(/\"timestamp\":\"([^\"]+)\"/g)) days.add(localDay(m[1]));
    for (const day of days) sessionsByDay.set(day, (sessionsByDay.get(day) || 0) + 1);
  }
}

const entries = rows.map(r => ({
  user_name: user,
  org_id: org,
  usage_date: r.period,
  input_tokens: r.inputTokens,
  output_tokens: r.outputTokens,
  cache_creation_tokens: r.cacheCreationTokens,
  cache_read_tokens: r.cacheReadTokens,
  total_cost_usd: r.totalCost,
  session_count: sessionsByDay.get(r.period) || 0,
  model_breakdown: Object.fromEntries((r.modelsUsed||[]).map(name => [name, {}]))
}));
process.stdout.write(JSON.stringify(entries));
" > /tmp/gh_daily.json && \
curl -sS --fail-with-body --connect-timeout 5 --max-time 15 --retry 2 \
  -X POST "${GREENHOUSE_URL}/rest/v1/claude_usage_daily?on_conflict=user_name,usage_date" \
  -H "Content-Type: application/json" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Prefer: resolution=merge-duplicates,return=minimal" \
  --data-binary @/tmp/gh_daily.json && echo "daily: OK"
```

Always targets Supabase PostgREST directly — not the Next.js `/api/claude-usage` route.

---

## Step 2: Push Project Usage

`ccusage`'s `--instances` flag is gone, but `ccusage session --json` gives us authoritative per-session cost (with proper subagent dedup, model-aware rates, and synthetic-message filtering — all of which a naive JSONL walk gets wrong). Each Claude session lives in exactly one project directory at `~/.claude/projects/{path-as-dashes}/{session-uuid}.jsonl`, so we can index session UUID → project dir via a single readdir and aggregate ccusage costs by project. The folder name encodes the project path; the session's `metadata.lastActivity` gives last-activity.

**Only changed projects.** A project row is a lifetime aggregate, so a project with no session file written since the last sync (`~/.greenhouse/last-usage-sync`) has nothing new to say — skip its directory entirely. Dirs with any `.jsonl` modified since then are re-aggregated in full and upserted. No file yet → every dir.

We trust ccusage's pricing end-to-end — no local pricing table to maintain. Sessions whose JSONL files have been rotated/deleted (older history) still appear in `claude_usage_daily` but are skipped here since we can't attribute them to a project on disk.

Each row is also linked to a Greenhouse project when possible: the script recovers the real on-disk path from the JSONL's `cwd` field (more reliable than dash-decoding the folder name, since project folders themselves can contain hyphens), then matches `git remote get-url origin` against `projects.repository_url`. When the `work-ticket` skill is active in a session, it leaves a `.greenhouse-ticket` marker file in that project's `~/.claude/projects/{path-as-dashes}/` directory — the script reads it to set `ticket_id`.

```bash
node -e "
const fs = require('fs'), path = require('path'), os = require('os');
const { execSync } = require('child_process');
const root = path.join(os.homedir(), '.claude', 'projects');
const user = '${GREENHOUSE_TEAM_USERNAME}';
const org  = '${GREENHOUSE_ORG_ID}';

// 1) Index every Claude session UUID -> project dir from the on-disk JSONL files,
//    and capture the first \`cwd\` per dir (authoritative real-disk path).
const uuidToDir = new Map();
const dirToRealPath = new Map();
const dirToTicket  = new Map();
let lastSync = 0;
try { lastSync = Date.parse(fs.readFileSync(path.join(os.homedir(), '.greenhouse', 'last-usage-sync'), 'utf8').trim()) || 0; } catch {}
function firstCwd(filePath) {
  // Read first ~50KB; the cwd appears on early user-message events.
  const buf = Buffer.alloc(50 * 1024);
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    const head = buf.slice(0, n).toString('utf8');
    for (const line of head.split('\\n')) {
      if (!line.includes('\"cwd\"')) continue;
      try { const e = JSON.parse(line); if (e.cwd) return e.cwd; } catch {}
    }
  } catch {} finally { if (fd) try { fs.closeSync(fd); } catch {} }
  return null;
}
for (const dir of fs.existsSync(root) ? fs.readdirSync(root) : []) {
  const pd = path.join(root, dir);
  if (!fs.statSync(pd).isDirectory()) continue;
  // Unchanged since the last sync -> its row is already current; skip the dir.
  // (A dir's own mtime doesn't move when a session file is appended, so check the files.)
  const jsonl = fs.readdirSync(pd).filter(f => f.endsWith('.jsonl'));
  if (!jsonl.some(f => fs.statSync(path.join(pd, f)).mtimeMs >= lastSync)) continue;
  // Ticket marker, if work-ticket left one for this project's active session.
  try {
    const mp = path.join(pd, '.greenhouse-ticket');
    if (fs.existsSync(mp)) {
      const v = fs.readFileSync(mp, 'utf8').trim();
      if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$/.test(v)) dirToTicket.set(dir, v);
    }
  } catch {}
  for (const f of jsonl) {
    uuidToDir.set(f.slice(0, -6), dir);
    if (!dirToRealPath.has(dir)) {
      const cwd = firstCwd(path.join(pd, f));
      if (cwd) dirToRealPath.set(dir, cwd);
    }
  }
}

// 2) Pull ccusage session data — agent='claude' filter drops codex/other CLIs.
const ccu = JSON.parse(execSync('npx ccusage@latest session --json 2>/dev/null',
  { maxBuffer: 256 * 1024 * 1024 }).toString());
const sessions = (ccu.session || []).filter(s => s.agent === 'claude');

// 3) Aggregate per project_dir.
const byDir = new Map();
for (const s of sessions) {
  const dir = uuidToDir.get(s.period);
  if (!dir) continue; // session JSONL no longer on disk; daily total still captures it
  const cur = byDir.get(dir) || { input:0, output:0, cw:0, cr:0, cost:0, sessions:0, last:'' };
  cur.input    += s.inputTokens || 0;
  cur.output   += s.outputTokens || 0;
  cur.cw       += s.cacheCreationTokens || 0;
  cur.cr       += s.cacheReadTokens || 0;
  cur.cost     += s.totalCost || 0;
  cur.sessions += 1;
  const la = s.metadata?.lastActivity || '';
  if (la > cur.last) cur.last = la;
  byDir.set(dir, cur);
}

// 4) Resolve project_id for each dir: git remote -> projects.repository_url.
//    'owner/repo' is the comparable substring; both ssh and https remote forms
//    contain it. ilike on repository_url tolerates trailing .git, query strings,
//    or http/https prefix variation in the stored project.
function ownerRepo(realPath) {
  if (!realPath) return null;
  let url;
  try { url = execSync('git -C ' + JSON.stringify(realPath) + ' config --get remote.origin.url 2>/dev/null',
    { stdio: ['ignore','pipe','ignore'] }).toString().trim(); } catch { return null; }
  if (!url) return null;
  const m = url.match(/[:\\/]([^:\\/]+)\\/([^\\/]+?)(?:\\.git)?\$/);
  return m ? (m[1] + '/' + m[2]) : null;
}
async function lookupProjectId(or) {
  if (!or) return null;
  const r = await fetch(process.env.GREENHOUSE_URL + '/rest/v1/projects?repository_url=ilike.*' + encodeURIComponent(or) + '*&select=id',
    { headers: { apikey: process.env.GREENHOUSE_PUBLIC_KEY, Authorization: 'Bearer ' + process.env.GREENHOUSE_JWT } });
  if (!r.ok) return null;
  const rows = await r.json();
  return rows.length === 1 ? rows[0].id : null;
}

(async () => {
  const orToPid = new Map();
  const out = [];
  for (const [dir, v] of byDir) {
    const realPath = dirToRealPath.get(dir);
    const or = ownerRepo(realPath);
    let projectId = null;
    if (or) {
      if (!orToPid.has(or)) orToPid.set(or, await lookupProjectId(or));
      projectId = orToPid.get(or);
    }
    // project_path: prefer the JSONL-recorded cwd (authoritative). Fall back to
    // the lossy dash-decoded reconstruction for legacy display only.
    const project_path = realPath ||
      dir.replace(/^-([^-]+)-([^-]+)-(.+)/, '/\$1/\$2/\$3').replace(/^-/, '/');
    const category = dir.includes('co-work') ? 'co-work'
      : (dir.startsWith('-Users-') || dir.startsWith('-Volumes-')) ? 'repo'
      : 'other';
    out.push({
      user_name: user,
      org_id: org,
      project_id: projectId,
      ticket_id: dirToTicket.get(dir) || null,
      project_name: dir,
      project_path,
      category,
      total_tokens: v.input + v.output + v.cw + v.cr,
      total_cost_usd: Math.round(v.cost * 10000) / 10000,
      session_count: v.sessions,
      last_active_at: v.last || new Date().toISOString()
    });
  }
  process.stdout.write(JSON.stringify(out));
})();
" > /tmp/gh_projects.json && \
curl -sS --fail-with-body --connect-timeout 5 --max-time 15 --retry 2 \
  -X POST "${GREENHOUSE_URL}/rest/v1/claude_usage_projects?on_conflict=user_name,project_name" \
  -H "Content-Type: application/json" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Authorization: Bearer ${GREENHOUSE_JWT}" \
  -H "Prefer: resolution=merge-duplicates,return=minimal" \
  --data-binary @/tmp/gh_projects.json && echo "projects: OK"
```

When **both** steps printed OK, record this run as the last sync — the time captured before Step 1, so anything written during the run is picked up next time:

```bash
mv ~/.greenhouse/last-usage-sync.pending ~/.greenhouse/last-usage-sync
```

If either upsert failed, leave the pending file; the next run re-covers the same window.

---

## Step 3: Output Summary

```
## Claude Usage Synced

**User:** {display_name} ({initials})
**Today:** {today_tokens} tokens · ${today_cost}
**This Week:** {week_tokens} tokens · ${week_cost}
**Lifetime:** {lifetime_tokens} tokens · ${lifetime_cost}
**Projects:** {project_count} tracked

Last updated: {timestamp}
```

`{display_name}` and `{initials}` come from your `org_avatar_directory` row ([conventions §Current user resolution](../conventions/SKILL.md#current-user-resolution)) — display only; the rows above were written as `${GREENHOUSE_TEAM_USERNAME}`. If the lookup fails, show the username with its first two letters and note the fallback.

---

## Error Handling

| Error | Action |
|-------|--------|
| ccusage not installed | Show install command: `npm install -g ccusage` |
| No JSONL logs found | Note that Claude Code logs may be in a non-standard location |
| Greenhouse API unreachable | Log warning, show data locally anyway |
| ccusage output format unexpected | Adapt parsing, warn about format changes |
| 42501 / 403 on a usage upsert | The `user_name` you sent isn't your token's identity, or the row's `org_id` isn't your org — see [common-operations §identity on writes](../../references/common-operations.md#identity-on-writes) for the message to surface. Never retry with a locally-derived name. |

---

## Integration with Other Skills

When the `open-pr` or `work-ticket` skills complete their work, they should remind the user:

> "Want me to sync your Claude usage? I can update your token counts now."

This keeps usage data fresh without requiring a separate manual step.

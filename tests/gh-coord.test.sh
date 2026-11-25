#!/usr/bin/env bash
# Smoke tests for plugin/bin/gh-coord and gh-dash's report payload (GH-129).
# Each case builds a throwaway repo and state folder; nothing touches your real ~/.greenhouse.
#
#   bash plugin/tests/gh-coord.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
COORD="$HERE/../bin/gh-coord"
DASH="$HERE/../bin/gh-dash"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gh-coord-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
unset CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR GREENHOUSE_MAIN_REPO GREENHOUSE_LOCK_STALE_MIN GREENHOUSE_HEAVY_SLOTS GREENHOUSE_PLUGIN_DIR
export HOME="$ROOT/home"; mkdir -p "$HOME"
export GREENHOUSE_MARKERS_DIR="$ROOT/markers"   # where needs-you and gh-dash leave markers for seen

n=0; failed=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
not_ok() { n=$((n + 1)); failed=$((failed + 1)); echo "not ok $n - $1"; [ -n "${2:-}" ] && echo "#   $2"; }
check() { if eval "$2"; then ok "$1"; else not_ok "$1" "${3:-}"; fi; }
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# make_repo <dir> [extra fence lines...]
make_repo() {
  local dir="$1"; shift
  mkdir -p "$dir" && git -C "$dir" init -q
  { echo '# Test'; echo; echo '```greenhouse'; echo 'project_id: 00000000-0000-4000-8000-000000000001'; echo 'project_key: TST'
    for line in "$@"; do echo "$line"; done; echo '```'; } >"$dir/CLAUDE.md"
}

REPO="$ROOT/repo"; make_repo "$REPO" 'local_stack: tst   # trailing comment' 'db_commands: [pnpm db:seed, "pnpm test:db"]'
export GREENHOUSE_AGENTS_DIR="$ROOT/state"
gc() { (cd "$REPO" && "$COORD" "$@"); }

# ── config ─────────────────────────────────────────────────────────────────
out=$(gc config)
check "config reads the project key, stack and command list from the greenhouse block" \
  '[[ "$out" == *"KEY=TST"* && "$out" == *"LOCAL_STACK=tst"* && "$out" == *"DB_COMMANDS=pnpm db:seed; pnpm test:db"* ]]' "$out"

# ── claims ─────────────────────────────────────────────────────────────────
gc claim TST-1 TST-1/work "$ROOT/wt1" >/dev/null
out=$(gc claim TST-1 TST-1/fix "$ROOT/wt1"); rc=$?
check "a second claim under a different label returns TAKEN" '[ $rc -eq 1 ] && [[ "$out" == TAKEN* ]]' "rc=$rc out=$out"
out=$(gc claim TST-1 TST-1/work "$ROOT/wt1"); rc=$?
check "the same label re-claims as already mine" '[ $rc -eq 0 ] && [[ "$out" == *"already mine"* ]]' "rc=$rc out=$out"

# ── paths (GH-134: worktrees under .claude/worktrees) ──────────────────────
main=$(gc config | sed -n 's/^MAIN=//p')   # git's real path ($ROOT can sit behind a symlink)
out=$(gc paths TST-21); gc paths TST-21 >/dev/null
check "paths puts a ticket's worktree under .claude/worktrees and keeps the folder out of git status" \
  '[[ "$out" == *"WT=$main/.claude/worktrees/tst-21" ]] && [ "$(grep -cx "/.claude/worktrees/" "$REPO/.git/info/exclude")" = 1 ]' \
  "$out | $(grep -v "^#" "$REPO/.git/info/exclude" 2>/dev/null)"
mkdir -p "$main-22" && echo "gitdir: $main/.git/worktrees/repo-22" >"$main-22/.git"
out=$(gc paths TST-22)
check "paths keeps a ticket's existing worktree beside the main checkout" '[[ "$out" == *"WT=$main-22" ]]' "$out"

# ── working (GH-133: tend-ticket's pill) ───────────────────────────────────
tend() { (cd "$REPO" && CLAUDE_CODE_SESSION_ID=s-tend "$COORD" "$@"); }
tend working TST-20 tend >/dev/null
rec="$GREENHOUSE_AGENTS_DIR/chats/s-tend"
check "working sets the chat's ticket and role without a claim" \
  'grep -q "^ticket=TST-20$" "$rec" && grep -q "^role=tend$" "$rec" && [ ! -e "$GREENHOUSE_AGENTS_DIR/claims/TST-20" ]' "$(cat "$rec" 2>/dev/null)"
out=$(gc claim TST-20 TST-20/work "$ROOT/wt20"); rc=$?
check "a ticket someone is tending can still be claimed" '[ $rc -eq 0 ] && [ "$out" = CLAIMED ]' "rc=$rc out=$out"
gc unclaim TST-20 TST-20/work >/dev/null
tend working - >/dev/null
check "working - clears the chat's ticket and role" '! grep -q "^ticket=" "$rec" && ! grep -q "^role=" "$rec"' "$(cat "$rec")"
out=$(tend working TST-20 tending 2>&1); rc=$?
check "working refuses a role gh-dash doesn't know" '[ $rc -eq 64 ]' "rc=$rc out=$out"

# ── DB lock ────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/gone-wt"
gc db-acquire TST-2/work "$ROOT/gone-wt" "seed" >/dev/null
rmdir "$ROOT/gone-wt"
out=$(gc db-acquire TST-3/work "$REPO" "test" 2>/dev/null); rc=$?
check "a DB lock whose worktree is gone is broken and logged as db BROKE" \
  '[ $rc -eq 0 ] && grep -q "db BROKE stale lock: TST-2/work" "$GREENHOUSE_AGENTS_DIR/log"' "rc=$rc out=$out"
out=$(gc db-run TST-9/work -- true 2>&1); rc=$?
check "db-run refuses a label that doesn't hold the lock" '[ $rc -eq 3 ]' "rc=$rc out=$out"
gc db-release TST-3/work >/dev/null

# ── heavy slots ────────────────────────────────────────────────────────────
mkdir -p "$GREENHOUSE_AGENTS_DIR/heavy/slot1"
dead=$(sh -c 'echo $$')   # a pid that has already exited
printf 'label=TST-4/work\npath=%s\ncmd=pnpm build\npid=%s\nsince=x\n' "$REPO" "$dead" >"$GREENHOUSE_AGENTS_DIR/heavy/slot1/owner"
out=$(gc heavy-run TST-5/work -- echo ran 2>/dev/null); rc=$?
check "a heavy slot whose process died is reclaimed" \
  '[ $rc -eq 0 ] && [ "$out" = ran ] && grep -q "heavy BROKE stale slot1" "$GREENHOUSE_AGENTS_DIR/log"' "rc=$rc out=$out"

# ── doing text ─────────────────────────────────────────────────────────────
rec="$GREENHOUSE_AGENTS_DIR/chats/chat-doing"
out=$(cd "$REPO" && CLAUDE_CODE_SESSION_ID=chat-doing "$COORD" heavy-run TST-6/work -- env SECRET_TOKEN=abc123 sh -c 'grep "^doing=" "$0"' "$rec" 2>/dev/null)
check "doing text drops NAME=value pairs" '[[ "$out" == "doing=heavy: env sh -c"* && "$out" != *abc123* ]]' "$out"

# ── no local_stack ─────────────────────────────────────────────────────────
NOSTACK="$ROOT/nostack"; make_repo "$NOSTACK"
out=$(cd "$NOSTACK" && GREENHOUSE_AGENTS_DIR="$ROOT/state2" "$COORD" db-run TST-7/work -- sh -c 'echo inside; exit 7'); rc=$?
stack=$(cd "$NOSTACK" && GREENHOUSE_AGENTS_DIR="$ROOT/state2" "$COORD" db-stack)
check "with no local_stack, db-run runs without a lock" \
  '[ $rc -eq 7 ] && [ "$out" = inside ] && [ "$stack" = none ] && [ ! -d "$ROOT/state2/db.lock" ]' "rc=$rc out=$out stack=$stack"

# ── needs-you ──────────────────────────────────────────────────────────────
PLAIN="$ROOT/plain"; mkdir -p "$PLAIN"
hook='{"session_id":"s-unknown","transcript_path":"/tmp/x.jsonl","cwd":"'"$PLAIN"'","hook_event_name":"Notification"}'
out=$(printf '%s' "$hook" | GREENHOUSE_AGENTS_DIR="$ROOT/state3" "$COORD" needs-you permission_prompt 2>&1); rc=$?
check "needs-you exits 0 silently outside a repo with agents state" \
  '[ $rc -eq 0 ] && [ -z "$out" ] && [ ! -e "$ROOT/state3" ]' "rc=$rc out=$out"
# Hook timings are averaged over 10 calls, so the clock's own startup (python) doesn't dominate.
t0=$(ms); for _ in 1 2 3 4 5 6 7 8 9 10; do printf '%s' "$hook" | GREENHOUSE_AGENTS_DIR="$ROOT/state3" "$COORD" needs-you permission_prompt >/dev/null 2>&1; done; t1=$(ms)
per=$(( (t1 - t0) / 10 ))
echo "#   needs-you outside a repo took $per ms per call"
check "needs-you outside a repo returns in under 300 ms" '[ $per -lt 300 ]' "$per ms"

hook='{"session_id":"s-unknown","cwd":"'"$REPO"'"}'
printf '%s' "$hook" | "$COORD" needs-you idle_prompt
check "needs-you never creates a record for a chat the coordinator doesn't know" \
  '[ ! -e "$GREENHOUSE_AGENTS_DIR/chats/s-unknown" ]'

(cd "$REPO" && CLAUDE_CODE_SESSION_ID=s-known "$COORD" claim TST-8 TST-8/fix - >/dev/null)
hook='{"session_id":"s-known","transcript_path":"/tmp/s-known.jsonl","cwd":"'"$REPO"'"}'
printf '%s' "$hook" | "$COORD" needs-you permission_prompt
rec="$GREENHOUSE_AGENTS_DIR/chats/s-known"
check "needs-you records the type and transcript on a known chat" \
  'grep -q "^needs=permission_prompt$" "$rec" && grep -q "^transcript=/tmp/s-known.jsonl$" "$rec" && grep -q "^ticket=TST-8$" "$rec"' "$(cat "$rec")"
(cd "$REPO" && CLAUDE_CODE_SESSION_ID=s-known "$COORD" status >/dev/null)
check "the chat's next coordinator call clears needs-you" '! grep -q "^needs=" "$rec"' "$(cat "$rec")"

printf '%s' "$hook" | "$COORD" needs-you permission_prompt
printf '{"session_id":"s-known","hook_event_name":"PostToolUse"}' | "$COORD" seen
check "seen (the chat ran a tool) clears needs-you and its marker" \
  '! grep -q "^needs=" "$rec" && [ ! -e "$GREENHOUSE_MARKERS_DIR/needs/s-known" ]' "$(cat "$rec")"
# A chat gh-dash started: its first prompt (UserPromptSubmit) marks it as going.
printf 'since=x\nstarted_by=gh-dash\nstarted=1\nname=tst-11\nmode=terminal\n' >"$GREENHOUSE_AGENTS_DIR/chats/s-new"
mkdir -p "$GREENHOUSE_MARKERS_DIR/starting" && printf '%s' "$GREENHOUSE_AGENTS_DIR/chats/s-new" >"$GREENHOUSE_MARKERS_DIR/starting/s-new"
(cd "$REPO" && printf '{"session_id":"s-new","hook_event_name":"UserPromptSubmit"}' | "$COORD" seen)
check "seen marks a chat gh-dash started as going once it gets its first prompt" \
  'grep -q "^path=.*/repo$" "$GREENHOUSE_AGENTS_DIR/chats/s-new" && [ ! -e "$GREENHOUSE_MARKERS_DIR/starting/s-new" ]' "$(cat "$GREENHOUSE_AGENTS_DIR/chats/s-new")"
printf '{"session_id":"s-other"}' | "$COORD" seen; rc=$?
t0=$(ms); for _ in 1 2 3 4 5 6 7 8 9 10; do printf '{"session_id":"s-other"}' | "$COORD" seen; done; t1=$(ms)
per=$(( (t1 - t0) / 10 ))
echo "#   seen for an unmarked chat took $per ms per call"
check "seen for a chat with no marker returns at once and touches nothing" \
  '[ $rc -eq 0 ] && [ $per -lt 100 ] && [ ! -e "$GREENHOUSE_AGENTS_DIR/chats/s-other" ]' "rc=$rc $per ms"

# ── GH-134: an AskUserQuestion box drives the waiting flag ──────────────────
(cd "$REPO" && CLAUDE_CODE_SESSION_ID=s-box "$COORD" claim TST-14 TST-14/review - >/dev/null)
rec="$GREENHOUSE_AGENTS_DIR/chats/s-box"
hook='{"session_id":"s-box","cwd":"'"$REPO"'","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
printf '%s' "$hook" | "$COORD" needs-you question
first=$(sed -n 's/^needs_at=//p' "$rec")
sleep 1
printf '{"session_id":"s-box","cwd":"%s","hook_event_name":"Notification"}' "$REPO" | "$COORD" needs-you idle_prompt
check "needs-you question then idle_prompt keeps question and the first needs_at" \
  'grep -q "^needs=question$" "$rec" && [ -n "$first" ] && [ "$(sed -n "s/^needs_at=//p" "$rec")" = "$first" ]' "first=$first $(cat "$rec")"

printf '{"session_id":"s-box","hook_event_name":"PostToolUse","tool_name":"Bash"}' | "$COORD" seen
held=$(grep -c "^needs=question$" "$rec"); marker=$([ -e "$GREENHOUSE_MARKERS_DIR/needs/s-box" ] && echo yes || echo no)
printf '{"session_id":"s-box","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}' | "$COORD" seen box
check "generic seen doesn't clear a box's question, the AskUserQuestion PostToolUse does" \
  '[ "$held" = 1 ] && [ "$marker" = yes ] && ! grep -q "^needs" "$rec" && [ ! -e "$GREENHOUSE_MARKERS_DIR/needs/s-box" ]' \
  "held=$held marker=$marker $(cat "$rec")"

printf '%s' "$hook" | "$COORD" needs-you question
printf '{"session_id":"s-box","hook_event_name":"UserPromptSubmit"}' | "$COORD" seen prompt
check "UserPromptSubmit seen clears question" '! grep -q "^needs" "$rec" && [ ! -e "$GREENHOUSE_MARKERS_DIR/needs/s-box" ]' "$(cat "$rec")"

# ── GH-134: a /loop tick stamps when it ran and when the next is due ────────
loop() { (cd "$REPO" && CLAUDE_CODE_SESSION_ID="$1" "$COORD" tick ${2:+"$2"}); }
due_gap() { echo $(( $(sed -n 's/^tick_due=//p' "$1") - $(sed -n 's/^tick_at=//p' "$1") )); }
loop s-tick 7 >/dev/null
rec="$GREENHOUSE_AGENTS_DIR/chats/s-tick"
check "tick stamps tick_at and tick_due from the given minutes" \
  'grep -q "^tick_at=[0-9]*$" "$rec" && [ "$(due_gap "$rec")" -eq 420 ]' "$(cat "$rec")"

loop s-tick2 5 >/dev/null
rec="$GREENHOUSE_AGENTS_DIR/chats/s-tick2"
# The previous tick ended 10 minutes ago; this one starts now.
sed -i.bak "s/^tick_at=.*/tick_at=$(( $(date +%s) - 600 ))/" "$rec" && rm -f "$rec.bak"
before=$(date +%s)
loop s-tick2 >/dev/null
check "tick without minutes stamps tick_at and clears tick_due (a running tick has no due time)" \
  '[ "$(sed -n "s/^tick_at=//p" "$rec")" -ge "$before" ] && ! grep -q "^tick_due=" "$rec"' "$(cat "$rec")"
out=$(loop s-tick3 0 2>&1); rc=$?
check "tick refuses a zero or non-numeric interval" '[ $rc -eq 64 ]' "rc=$rc out=$out"

# ── gh-dash without node (GH-134) ──────────────────────────────────────────
mkdir -p "$ROOT/nonode"
out=$(cd "$REPO" && PATH="$ROOT/nonode" "$DASH" --report-preview 2>&1); rc=$?
check "gh-dash with no node on the PATH says so plainly and exits 127" \
  '[ $rc -eq 127 ] && [[ "$out" == "gh-dash: Node.js (18 or later) isn'"'"'t on the PATH"* ]]' "rc=$rc out=$out"

# ── gh-dash report payload ─────────────────────────────────────────────────
# Two chats gh-dash started three minutes ago: one never got going, one has called gh-coord since.
old=$(( $(date +%s) - 180 ))
printf 'since=x\nstarted_by=gh-dash\nstarted=%s\nname=tst-9\nmode=terminal\n' "$old" >"$GREENHOUSE_AGENTS_DIR/chats/s-stuck"
printf 'since=x\nstarted_by=gh-dash\nstarted=%s\nname=tst-10\nmode=terminal\npath=%s\n' "$old" "$REPO" >"$GREENHOUSE_AGENTS_DIR/chats/s-going"
# A tend chat gh-dash started on TST-8, which s-known holds a fix claim on.
printf 'since=x\nstarted_by=gh-dash\nstarted=%s\nname=tst-8 tend\nmode=terminal\nticket=TST-8\nrole=tend\npath=%s\n' "$(date +%s)" "$REPO" >"$GREENHOUSE_AGENTS_DIR/chats/s-tend"
if command -v node >/dev/null 2>&1 && [ -x "$DASH" ]; then
  # A work chat on TST-12 closed without unclaiming: no session open, last gh-coord call two hours ago.
  mkdir -p "$GREENHOUSE_AGENTS_DIR/claims/TST-12"
  printf 'label=TST-12/work\npath=%s\nsince=x\nchat=s-gone\n' "$REPO" >"$GREENHOUSE_AGENTS_DIR/claims/TST-12/owner"
  printf 'since=x\nticket=TST-12\nrole=work\nlabel=TST-12/work\npath=%s\ndoing=db: pnpm test:db\n' "$REPO" >"$GREENHOUSE_AGENTS_DIR/chats/s-gone"
  node -e 'const t = Date.now() / 1000 - 7200; require("fs").utimesSync(process.argv[1], t, t)' "$GREENHOUSE_AGENTS_DIR/chats/s-gone"
  # A review loop waiting on its box, which ticked two minutes ago and is due again in three.
  t=$(date +%s)
  printf 'since=x\nticket=TST-15\nrole=review\nlabel=TST-15/review\npath=%s\nneeds=question\nneeds_at=%s\ntick_at=%s\ntick_due=%s\n' \
    "$REPO" "$((t - 60))" "$((t - 120))" "$((t + 180))" >"$GREENHOUSE_AGENTS_DIR/chats/s-wait"
  payload=$(cd "$REPO" && GREENHOUSE_MACHINE=test-box "$DASH" --report-preview 2>/dev/null)
  check "report preview carries needs_since, last_tick_at and tick_due_at" \
    'printf "%s" "$payload" | node -e '"'"'
      const t = Number(process.argv[1]);
      const chats = JSON.parse(require("fs").readFileSync(0, "utf8")).p_chats;
      const c = chats.find((x) => x.session_id === "s-wait");
      const plain = chats.find((x) => x.session_id === "s-going");
      const at = (s) => (s ? Date.parse(s) / 1000 : NaN);
      process.exit(c && c.needs_you === "question" && at(c.needs_since) === t - 60 && at(c.last_tick_at) === t - 120
        && at(c.tick_due_at) === t + 180 && plain && plain.needs_since === null && plain.last_tick_at === null ? 0 : 1);'"'"' "$t"' "$payload"
  check "the machine snapshot is its slots and their commands, with no gauges, busy/idle or process list" \
    'printf "%s" "$payload" | node -e '"'"'
      const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const m = p.p_machine_state;
      const ok = p.p_machine === "test-box" && m.slots_total === 1 && Array.isArray(m.heavy_slots)
        && !("cpu_pct" in m) && !("mem_pct" in m) && !("top" in m) && !("processes" in m)
        && Array.isArray(p.p_chats) && p.p_chats.every((c) => !("path" in c) && !("transcript" in c) && !("status" in c) && !("seen_at" in c));
      process.exit(ok ? 0 : 1);'"'"'' "$payload"
  check "reported chats carry the folder name only, never a path" \
    'printf "%s" "$payload" | node -e '"'"'
      const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
      process.exit(p.p_chats.length > 0 && p.p_chats.every((c) => !String(c.folder || "").includes("/")) ? 0 : 1);'"'"'' "$payload"
  check "a tend chat on a claimed ticket keeps its own row instead of taking over the claim" \
    'printf "%s" "$payload" | node -e '"'"'
      const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const claim = p.p_chats.find((c) => c.session_id === "s-known");
      const tend = p.p_chats.find((c) => c.session_id === "s-tend");
      process.exit(claim && claim.role === "fix" && tend && tend.role === "tend" && tend.ticket === "TST-8" ? 0 : 1);'"'"'' "$payload"
  check "a chat gh-dash started that never got going reads as stuck at startup, one that called gh-coord doesn't" \
    'printf "%s" "$payload" | node -e '"'"'
      const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const by = Object.fromEntries(p.p_chats.map((c) => [c.session_id, c.needs_you]));
      process.exit(by["s-stuck"] === "startup" && by["s-going"] === null ? 0 : 1);'"'"'' "$payload"
  check "a claim whose chat closed and has been quiet an hour leaves the report; a recent one stays" \
    'printf "%s" "$payload" | node -e '"'"'
      const ids = JSON.parse(require("fs").readFileSync(0, "utf8")).p_chats.map((c) => c.session_id);
      process.exit(!ids.includes("s-gone") && ids.includes("s-known") ? 0 : 1);'"'"'' "$payload"
  # Started from inside a chat, gh-dash must not pass that chat's session variables to what it runs.
  leaked=$(cd "$REPO" && CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=parent GREENHOUSE_ENV_PROBE=1 "$DASH" --report-preview 2>&1 >/dev/null)
  check "gh-dash drops the parent chat's Claude Code session variables" '[ -z "$leaked" ]' "$leaked"

  # ── gh-dash against a fake Greenhouse ────────────────────────────────────
  # A copy of bin/ with a stand-in gh-jwt, a stand-in claude on PATH (background mode, so nothing
  # opens a window), and a Greenhouse that fails every report and has two starts queued.
  FAKE="$ROOT/fake"; mkdir -p "$FAKE/bin" "$FAKE/path"
  cp "$COORD" "$DASH" "$HERE/../bin/gh-api" "$FAKE/bin/"
  printf '#!/bin/sh\ncase "$1" in agents) echo "[]" ;; --bg) echo "backgrounded · 0123abcd" ;; esac\n' >"$FAKE/path/claude"
  # ps feeds only the page's process list, so each call it logs is a page-only reading.
  printf '#!/bin/sh\necho ps >>"%s"\n' "$FAKE/ps-calls" >"$FAKE/path/ps"
  chmod +x "$FAKE/path/claude" "$FAKE/path/ps"
  node -e '
    const http = require("http"), fs = require("fs");
    let queued = 2;
    http.createServer((req, res) => {
      let sent = "";
      req.on("data", (c) => { sent += c; });
      req.on("end", () => {
        const fn = req.url.split("/").pop();
        fs.appendFileSync(process.argv[1], fn + "\n");
        const reply = (code, body) => { res.writeHead(code, { "content-type": "application/json" }); res.end(body); };
        // gh-api checks: echo what arrived, or fail.
        if (fn.startsWith("echo")) return reply(200, JSON.stringify({ method: req.method, apikey: req.headers.apikey,
          auth: req.headers.authorization, prefer: req.headers.prefer || null, body: sent }));
        if (fn.startsWith("fail")) return reply(400, "{\"message\":\"nope\"}");
        if (fn === "report_agent_state") return reply(500, "{\"message\":\"boom\"}");
        if (fn === "take_agent_start") return reply(200, JSON.stringify(queued-- > 0 ? [{ id: "r" + queued, kind: "review", ticket_number: 40 + queued }] : []));
        reply(204, "");
      });
    }).listen(0, "127.0.0.1", function () { fs.writeFileSync(process.argv[2], String(this.address().port)); });
  ' "$FAKE/calls" "$FAKE/port" &
  fake=$!
  for _ in $(seq 50); do [ -s "$FAKE/port" ] && break; sleep 0.1; done
  printf "#!/bin/sh\necho \"export GREENHOUSE_URL='http://127.0.0.1:%s'\"\necho \"export GREENHOUSE_PUBLIC_KEY='pk'\"\necho \"export GREENHOUSE_JWT='jwt'\"\n" \
    "$(cat "$FAKE/port")" >"$FAKE/bin/gh-jwt"
  chmod +x "$FAKE/bin/gh-jwt"
  echo background >"$GREENHOUSE_AGENTS_DIR/start-mode"
  # Reports go out on a 2 s tick from about 2 s in; the queue's first check is about 5 s in.
  GREENHOUSE_MAIN_REPO="$REPO" PATH="$FAKE/path:$PATH" GREENHOUSE_DASH_PORT=$((30000 + RANDOM % 20000)) \
    node "$FAKE/bin/gh-dash" >"$FAKE/dash.log" 2>&1 &
  dash=$!
  sleep 9
  calls=$(cat "$FAKE/calls" 2>/dev/null)
  idle_ps=$(cat "$FAKE/ps-calls" 2>/dev/null | wc -l | tr -d ' ')
  curl -s -o /dev/null "http://127.0.0.1:$(cat "$GREENHOUSE_AGENTS_DIR/dash.port")/api/state"
  sleep 1
  page_ps=$(cat "$FAKE/ps-calls" 2>/dev/null | wc -l | tr -d ' ')
  api=$("$FAKE/bin/gh-api" PATCH '/rest/v1/echo?display_id=eq.TST-1' '{"status":"in_review"}'); api_rc=$?
  api_err=$("$FAKE/bin/gh-api" GET /rest/v1/fail 2>&1 >/dev/null); api_err_rc=$?
  kill "$dash" "$fake" 2>/dev/null; wait "$dash" "$fake" 2>/dev/null
  check "gh-api sends the session headers and the payload, and asks for the written rows back" \
    '[ $api_rc -eq 0 ] && printf "%s" "$api" | node -e '"'"'
      const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
      process.exit(r.method === "PATCH" && r.apikey === "pk" && r.auth === "Bearer jwt" && r.prefer === "return=representation"
        && r.body === "{\"status\":\"in_review\"}" ? 0 : 1);'"'"'' "rc=$api_rc $api"
  check "gh-api exits 1 on an HTTP error and prints the status and body on stderr" \
    '[ $api_err_rc -eq 1 ] && [[ "$api_err" == *"HTTP 400"* && "$api_err" == *nope* ]]' "rc=$api_err_rc $api_err"
  reports=$(printf '%s\n' "$calls" | grep -c '^report_agent_state$')
  takes=$(printf '%s\n' "$calls" | grep -c '^take_agent_start$')
  finishes=$(printf '%s\n' "$calls" | grep -c '^finish_agent_start$')
  check "a failed report waits 10 s before gh-dash tries again" '[ "$reports" -eq 1 ]' "reports=$reports $(tr '\n' ' ' <"$FAKE/dash.log")"
  check "one queue check takes every queued start, not just the first" \
    '[ "$takes" -eq 3 ] && [ "$finishes" -eq 2 ]' "takes=$takes finishes=$finishes $(tr '\n' ' ' <"$FAKE/dash.log")"
  check "with no page open gh-dash spawns none of the page's readings; a page load runs them" \
    '[ "$idle_ps" -eq 0 ] && [ "$page_ps" -ge 1 ]' "ps calls: idle=$idle_ps after page load=$page_ps"

  # ── chat names ───────────────────────────────────────────────────────────
  # The stand-in claude writes no session file, so every chat it starts stays invisible as open: the
  # case where only gh-dash's own record of the names it gave out keeps two chats from sharing one.
  NM="$ROOT/names"; mkdir -p "$NM/bin" "$NM/state"; cp "$COORD" "$DASH" "$NM/bin/"
  echo background >"$NM/state/start-mode"
  nm_up() {
    GREENHOUSE_AGENTS_DIR="$NM/state" GREENHOUSE_MAIN_REPO="$REPO" PATH="$FAKE/path:$PATH" GREENHOUSE_DASH_PORT=$((30000 + RANDOM % 20000)) \
      node "$NM/bin/gh-dash" >>"$NM/dash.log" 2>&1 &
    nm_dash=$!
    for _ in $(seq 50); do [ -s "$NM/state/dash.port" ] && break; sleep 0.1; done
  }
  nm_start() {
    curl -s -X POST -H 'x-gh-dash: 1' -d "$1" "http://127.0.0.1:$(cat "$NM/state/dash.port")/api/start" \
      | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).name || "?")'
  }
  nm_up
  names="$(nm_start '{"kind":"review"}'), $(nm_start '{"kind":"review"}'), $(nm_start '{"kind":"fix","ticket":"7"}'), $(nm_start '{"kind":"fix","ticket":"7"}')"
  # GH-138: sow takes no ticket, so one sent along is ignored.
  sow=$(curl -s -X POST -H 'x-gh-dash: 1' -d '{"kind":"sow","ticket":"7"}' "http://127.0.0.1:$(cat "$NM/state/dash.port")/api/start" \
    | node -e 'const o = JSON.parse(require("fs").readFileSync(0, "utf8")); process.stdout.write(`${o.name} ${o.run}`)')
  # An open tst-sow chat (here a background one, so no window to focus) comes forward instead.
  mkdir -p "$HOME/.claude/sessions"; sleep 30 & sow_pid=$!
  printf '{"pid":%s,"sessionId":"s-sow","cwd":"%s","name":"tst-sow","kind":"bg"}\n' "$sow_pid" "$REPO" >"$HOME/.claude/sessions/$sow_pid.json"
  sow_open=$(curl -s -X POST -H 'x-gh-dash: 1' -d '{"kind":"sow"}' "http://127.0.0.1:$(cat "$NM/state/dash.port")/api/start" \
    | node -e 'const o = JSON.parse(require("fs").readFileSync(0, "utf8")); process.stdout.write(`${o.name} ${o.already} ${o.attach}`)')
  kill "$sow_pid" 2>/dev/null; wait "$sow_pid" 2>/dev/null; rm -f "$HOME/.claude/sessions/$sow_pid.json"
  kill "$nm_dash" 2>/dev/null; wait "$nm_dash" 2>/dev/null
  nm_up
  again=$(nm_start '{"kind":"review"}')
  kill "$nm_dash" 2>/dev/null; wait "$nm_dash" 2>/dev/null
  check "loop chats take the next number, and a ticket chat that doesn't show as open is numbered, not reused" \
    '[ "$names" = "tst-review 1, tst-review 2, tst-7 fix, tst-7 fix 2" ]' "$names $(tr '\n' ' ' <"$NM/dash.log")"
  check "a restarted gh-dash remembers the names it gave out today" '[ "$again" = "tst-review 3" ]' "$again"
  check "sow runs /greenhouse:sow-feedback in <key>-sow, ignoring a ticket number" \
    '[ "$sow" = "tst-sow /greenhouse:sow-feedback" ]' "$sow"
  check "an open <key>-sow chat comes forward instead of a second one starting" \
    '[ "$sow_open" = "tst-sow true claude attach tst-sow" ]' "$sow_open"

  # A sow chat claims no ticket, so its record carries its role. A background start writes the record
  # once `claude agents` lists the new session, which this stand-in claude does.
  SW="$ROOT/sowrole"; mkdir -p "$SW/path" "$SW/state"; echo background >"$SW/state/start-mode"
  cat >"$SW/path/claude" <<'EOF'
#!/bin/sh
case "$1" in agents) echo '[{"sessionId":"0123abcd-0000-4000-8000-000000000138"}]' ;; --bg) echo "backgrounded · 0123abcd" ;; esac
EOF
  chmod +x "$SW/path/claude"
  GREENHOUSE_AGENTS_DIR="$SW/state" GREENHOUSE_MAIN_REPO="$REPO" PATH="$SW/path:$PATH" GREENHOUSE_DASH_PORT=$((30000 + RANDOM % 20000)) \
    node "$NM/bin/gh-dash" >>"$SW/dash.log" 2>&1 &
  sw_dash=$!
  for _ in $(seq 50); do [ -s "$SW/state/dash.port" ] && break; sleep 0.1; done
  curl -s -X POST -H 'x-gh-dash: 1' -d '{"kind":"sow"}' "http://127.0.0.1:$(cat "$SW/state/dash.port")/api/start" >/dev/null
  sow_rec="$SW/state/chats/0123abcd-0000-4000-8000-000000000138"
  for _ in $(seq 50); do [ -s "$sow_rec" ] && break; sleep 0.1; done
  kill "$sw_dash" 2>/dev/null; wait "$sw_dash" 2>/dev/null
  check "a sow chat's record carries role=sow and no ticket, so Greenhouse files it under sow" \
    'grep -q "^name=tst-sow$" "$sow_rec" && grep -q "^role=sow$" "$sow_rec" && ! grep -q "^ticket=" "$sow_rec"' "$(cat "$sow_rec" 2>/dev/null)"

  # ── GH-136: stopping gh-dash and one of its chats ────────────────────────
  # A Greenhouse that answers every report and records which ones were stopping reports, a stand-in
  # claude on PATH (no fake ps here: both stop paths read real command lines), and two state folders.
  ST="$ROOT/stop"; mkdir -p "$ST/bin" "$ST/path" "$ST/s1/chats" "$ST/s2" "$HOME/.claude/sessions" "$ROOT/elsewhere"
  cp "$COORD" "$DASH" "$ST/bin/" && cp "$FAKE/path/claude" "$ST/path/"
  printf 'setTimeout(() => {}, 60000);\n' >"$ST/claude"   # a chat's process: its command line contains "claude"
  # A process that ignores SIGTERM. Its first argument ("gh-dash" or "claude") puts that word in its
  # command line, and it creates the file named second once its handler is in place.
  printf 'process.on("SIGTERM", () => {});\nrequire("fs").writeFileSync(process.argv[3], "");\nsetTimeout(() => {}, 30000);\n' >"$ST/stubborn"
  node -e '
    const http = require("http"), fs = require("fs");
    http.createServer((req, res) => {
      let sent = "";
      req.on("data", (c) => { sent += c; });
      req.on("end", () => {
        const fn = req.url.split("?")[0].split("/").pop();
        let stopping = false;
        try { stopping = JSON.parse(sent).p_stopping === true; } catch {}
        fs.appendFileSync(process.argv[1], fn + (stopping ? " stopping" : "") + "\n");
        res.writeHead(200, { "content-type": "application/json" });
        res.end(fn === "report_agent_state" ? "true" : "[]");
      });
    }).listen(0, "127.0.0.1", function () { fs.writeFileSync(process.argv[2], String(this.address().port)); });
  ' "$ST/calls" "$ST/port" &
  st_fake=$!
  for _ in $(seq 50); do [ -s "$ST/port" ] && break; sleep 0.1; done
  printf "#!/bin/sh\necho \"export GREENHOUSE_URL='http://127.0.0.1:%s'\"\necho \"export GREENHOUSE_PUBLIC_KEY='pk'\"\necho \"export GREENHOUSE_JWT='jwt'\"\n" \
    "$(cat "$ST/port")" >"$ST/bin/gh-jwt"
  chmod +x "$ST/bin/gh-jwt"
  # st_up <state>: serves from that state folder; waits until dash.pid names the new process.
  st_up() {
    GREENHOUSE_AGENTS_DIR="$1" GREENHOUSE_MAIN_REPO="$REPO" PATH="$ST/path:$PATH" GREENHOUSE_DASH_PORT=$((30000 + RANDOM % 20000)) \
      node "$ST/bin/gh-dash" >>"$ST/dash.log" 2>&1 &
    st_pid=$!
    for _ in $(seq 50); do [ "$(cat "$1/dash.pid" 2>/dev/null)" = "$st_pid" ] && [ -s "$1/dash.port" ] && break; sleep 0.1; done
  }
  st_cmd() { (cd "$REPO" && GREENHOUSE_AGENTS_DIR="$1" GREENHOUSE_MAIN_REPO="$REPO" PATH="$ST/path:$PATH" node "$ST/bin/gh-dash" "${@:2}" 2>&1); }
  st_url() { echo "http://127.0.0.1:$(cat "$1/dash.port")"; }
  cmd_has() { ps -o command= -p "$1" 2>/dev/null | grep -q -- "$2"; }   # a zombie or a gone pid matches nothing
  bg_pid() { sh -c '"$@" </dev/null >/dev/null 2>&1 & echo $!' _ "$@"; }   # orphaned at once, so init reaps it
  # stubborn <gh-dash|claude>: starts one, waits until it ignores SIGTERM, and prints its pid.
  stubborn() {
    rm -f "$ST/ready"; local p; p=$(bg_pid node "$ST/stubborn" "$1" "$ST/ready")
    for _ in $(seq 50); do [ -e "$ST/ready" ] && break; sleep 0.1; done
    echo "$p"
  }
  # A session file as Claude Code writes one: session_file <pid> <session id> <cwd> <name>
  session_file() { printf '{"pid":%s,"sessionId":"%s","cwd":"%s","name":"%s"}\n' "$1" "$2" "$3" "$4" >"$HOME/.claude/sessions/$1.json"; }
  # The page's own card() run on a row of /api/state, against a stand-in DOM (any property or call
  # returns the stand-in, so the page script loads). Prints {stopped, open, card} for the ticket's row.
  render_card() {
    local state; state=$(curl -s "$1/api/state")
    curl -s "$1/" | node -e '
      const vm = require("vm");
      const html = require("fs").readFileSync(0, "utf8"), s = JSON.parse(process.argv[1]);
      const el = new Proxy(() => {}, { get: (t, p) => (p === Symbol.toPrimitive ? () => "" : el), apply: () => el, set: () => true });
      const ctx = vm.createContext({ document: el, fetch: () => new Promise(() => {}), setInterval: () => 0, setTimeout: () => 0, clearTimeout() {}, clearInterval() {}, confirm: () => false });
      vm.runInContext(html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>")), ctx);
      const r = s.rows.find((x) => x.ticket === process.argv[2]);
      process.stdout.write(r ? JSON.stringify({ stopped: r.stopped, open: !!(r.chat && r.chat.open), card: ctx.card(r, s.now) }) : "no row");
    ' "$state" "$2"
  }
  # The page's own script run in node's vm against a small DOM. Elements, looked up by id or
  # selector, keep what's set on them and the listeners added to them. querySelectorAll returns the
  # stop buttons the cards drew, as new objects on each redraw like a browser's. The clock moves only
  # when told, and the test answers fetch and confirm itself.
  # page_run <page.html> <state with TST-30's chat open> prints two lines, each "ok" or what failed:
  # the card octagon, then the header Stop.
  page_run() {
    node -e '
      const vm = require("vm"), fs = require("fs");
      const html = fs.readFileSync(process.argv[1], "utf8"), open = JSON.parse(process.argv[2]);
      const row = open.rows.find((r) => r.ticket === "TST-30"), id1 = row.chat.id, id2 = "3a3a3a3a-0000-4000-8000-0000000000aa";
      const two = { ...open, rows: [row, { ...row, ticket: "TST-31", label: "TST-31/work", chat: { ...row.chat, id: id2, name: "tst-31" } }] };
      const els = new Map(), doc = { activeElement: null, title: "", on: {} };
      const el = (key) => {
        if (!els.has(key)) {
          const t = { textContent: "", innerHTML: "", outerHTML: "", className: "", title: "", value: "", disabled: false, scrollTop: 0, style: {}, on: {} };
          Object.assign(t, {
            addEventListener: (type, fn) => { t.on[type] = fn; }, querySelector: (sel) => el(key + " " + sel), getAttribute: () => null,
            classList: { toggle() {}, add() {}, remove() {}, contains: () => false }, focus: () => { doc.activeElement = t; }, closest: () => null,
          });
          els.set(key, t);
        }
        return els.get(key);
      };
      const button = (id) => {
        const b = { disabled: false, focus: () => { doc.activeElement = b; } };
        b.getAttribute = (n) => (n === "data-stop" ? id : n === "data-name" ? (id === id1 ? "tst-30" : "tst-31") : null);
        return b;
      };
      Object.assign(doc, {
        getElementById: (id) => el("#" + id), querySelector: (sel) => el(sel), addEventListener: (type, fn) => { doc.on[type] = fn; },
        querySelectorAll: () => [...els.values()].flatMap((t) => [...String(t.innerHTML).matchAll(/data-stop="([^"]+)"/g)].map((m) => button(m[1]))),
      });
      let now = 0, seq = 0, state = two, holdState = false, yes = false, printed = 0;
      const timers = new Map(), calls = [], asked = [];
      const later = (fn, ms, every) => { timers.set(++seq, { fn, at: now + ms, every }); return seq; };
      const advance = (ms) => {
        for (const end = now + ms; ;) {
          const due = [...timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
          if (!due) { now = end; return; }
          const [id, t] = due; now = t.at;
          if (t.every) t.at += t.every; else timers.delete(id);
          t.fn();
        }
      };
      const answer = (body) => ({ ok: true, status: 200, json: () => Promise.resolve(body) });
      const fetch = (url, opts) => {
        const c = { url, opts: opts || {} };
        calls.push(c);
        if (url === "/api/state" && !holdState) return Promise.resolve(answer(state));
        return new Promise((resolve, reject) => { c.reply = (body) => resolve(answer(body)); c.fail = () => reject(new Error("down")); });
      };
      const ctx = vm.createContext({
        document: doc, fetch, confirm: (m) => { asked.push(m); return yes; },
        setTimeout: (fn, ms) => later(fn, ms || 0, 0), setInterval: (fn, ms) => later(fn, ms, ms), clearTimeout: (id) => timers.delete(id), clearInterval: (id) => timers.delete(id),
      });
      const flush = () => new Promise((r) => setImmediate(r));
      const last = (url) => calls.filter((c) => c.url === url).pop();
      const count = (url) => calls.filter((c) => c.url === url).length;
      (async () => {
        vm.runInContext(html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>")), ctx);
        await flush();
        const cards = () => el("#st-work .cards").innerHTML, hint = el("#hint"), link = el("#link");
        const armed = (id) => cards().includes(`class="stopc armed" data-stop="${id}"`);
        const click = (id) => el(".mimic").on.click({ target: { closest: () => button(id) } });
        const card = [], stop = [];
        const expect = (list, name, ok) => { if (!ok) list.push(name); };
        const say = (list) => { console.log(list.length ? list.join("; ") : "ok"); printed++; };

        // The card octagon, armed from the keyboard: focus is on it when the first press arms it.
        const was = doc.activeElement = button(id1);
        click(id1);
        expect(card, "the first click arms it at once", armed(id1) && cards().includes("<span>stop?</span>") && !last("/api/stop-chat"));
        expect(card, "focus is back on it after the redraw", doc.activeElement !== was && doc.activeElement.getAttribute("data-stop") === id1);
        const drawn = cards();
        state = JSON.parse(JSON.stringify(two)); state.rows[0].chat.seen -= 120e3;   // the next poll brings a change, so it redraws
        advance(2000); await flush();
        expect(card, "the 2 s poll redraws and keeps it armed", cards() !== drawn && armed(id1));
        advance(999); await flush();
        expect(card, "still armed just before 3 s", armed(id1));
        advance(1); await flush();
        expect(card, "3 s disarms it", !cards().includes("stopc armed"));
        click(id1); doc.on.keydown({ key: "Escape" });
        expect(card, "Esc disarms it", !cards().includes("stopc armed"));
        click(id1); click(id2);
        expect(card, "arming another card disarms the first", armed(id2) && !armed(id1));
        click(id2);
        const sent = last("/api/stop-chat");
        expect(card, "the second click posts the stop with the page header",
          !!sent && sent.opts.method === "POST" && sent.opts.headers["x-gh-dash"] === "1" && JSON.parse(sent.opts.body).session === id2);
        expect(card, "the card reads stopping while it waits", cards().includes(`disabled data-stop="${id2}"`) && cards().includes("stopping&hellip;"));
        if (sent) sent.reply({ stopped: true });
        await flush();
        expect(card, "a stop names the chat in the hint", hint.textContent === "tst-31 stopped" && hint.className === "hint g" && !cards().includes("stopping&hellip;"));
        click(id1); click(id1);
        last("/api/stop-chat").reply({ error: "tst-30 is still running after 5 s (pid 9)" }); await flush();
        expect(card, "a chat still running shows the error and gets its octagon back",
          hint.textContent === "tst-30 is still running after 5 s (pid 9)" && hint.className === "hint r" && cards().includes(`class="stopc" data-stop="${id1}"`));

        say(card);

        // The header Stop: the question counts the open chats, and Cancel sends nothing.
        const ask = (n) => "Stop gh-dash for tst?" + (n ? `\n\n${n} open ${n === 1 ? "chat" : "chats"} on this machine will show as ended in Greenhouse. The chats themselves keep running.` : "");
        const pressStop = () => el("#stop").on.click();
        for (const rows of [two.rows, [row], []]) {
          state = { ...two, rows }; advance(2000); await flush(); pressStop();
          expect(stop, `Cancel with ${rows.length} open asks the right question and sends nothing`, asked.pop() === ask(rows.length) && !last("/api/stop"));
        }
        yes = true; pressStop();
        last("/api/stop").fail(); await flush();
        const polls = count("/api/state");
        advance(2000); await flush();
        expect(stop, "a stop that fails says gh-dash is not answering and keeps polling",
          hint.textContent === "gh-dash is not answering" && count("/api/state") === polls + 1 && link.textContent === "● CONNECTED");
        holdState = true; advance(2000); await flush();
        const inFlight = last("/api/state");
        pressStop(); last("/api/stop").reply({ stopping: true }); await flush();
        const panel = el(".mimic").outerHTML;
        expect(stop, "a stop shows the stopped panel with the line that starts it again",
          panel.includes("gh-dash stopped") && panel.includes("! gh-dash --detach --open") && panel.includes("reload this page once it"));
        expect(stop, "the status reads STOPPED and Stop is disabled", link.textContent === "● STOPPED" && el("#stop").disabled === true);
        const before = ctx.lastState, after = count("/api/state");
        inFlight.reply(two); await flush(); advance(10000); await flush();
        expect(stop, "the poll in flight is dropped and polling stops",
          link.textContent === "● STOPPED" && ctx.lastState === before && count("/api/state") === after);

        say(stop);
      })().catch((e) => {
        // Only the lines not printed yet read as crashed, so a crash in the Stop part leaves the card line standing.
        const why = "crashed: " + String(e && e.stack || e).split("\n").slice(0, 3).join(" | ");
        while (printed < 2) { console.log(why); printed++; }
      });
    ' "$1" "$2" 2>&1
  }

  out=$(st_cmd "$ST/s1" --stop); rc=$?
  check "--stop with no dashboard running prints not running and exits 0" \
    '[ $rc -eq 0 ] && [ "$out" = "gh-dash: not running for TST" ]' "rc=$rc out=$out"

  other=$(bg_pid sleep 30)
  echo "$other" >"$ST/s1/dash.pid"; echo 1 >"$ST/s1/dash.port"
  out=$(st_cmd "$ST/s1" --stop); rc=$?
  alive_after=$(kill -0 "$other" 2>/dev/null && echo yes || echo no)
  st_up "$ST/s1"; a=$st_pid   # dash.pid and dash.port still name the sleep: a start must serve, not say already running
  check "--stop ignores a dash.pid that points at a live non-gh-dash process" \
    '[ $rc -eq 0 ] && [ "$out" = "gh-dash: not running for TST" ] && [ "$alive_after" = yes ] && [ "$(cat "$ST/s1/dash.pid" 2>/dev/null)" = "$a" ] && [ "$(cat "$ST/s1/dash.port")" != 1 ]' \
    "rc=$rc out=$out sleep alive=$alive_after dash.pid=$(cat "$ST/s1/dash.pid" 2>/dev/null) a=$a $(tail -3 "$ST/dash.log")"
  kill "$other" 2>/dev/null

  st_up "$ST/s2"; b=$st_pid
  out=$(st_cmd "$ST/s1" --stop); rc=$?
  check "--stop stops this repo's dashboard (process gone, dash.pid gone) and leaves another state folder's dashboard running" \
    '[ $rc -eq 0 ] && [ "$out" = "gh-dash: stopped for TST (pid $a)" ] && ! cmd_has "$a" gh-dash && [ ! -e "$ST/s1/dash.pid" ] && cmd_has "$b" gh-dash && [ -s "$ST/s2/dash.pid" ]' \
    "rc=$rc out=$out"

  stub=$(stubborn gh-dash)
  echo "$stub" >"$ST/s1/dash.pid"; echo 1 >"$ST/s1/dash.port"
  out=$(st_cmd "$ST/s1" --stop); rc=$?
  check "--stop reports a dashboard still running after 5 s, exits 1, and never SIGKILLs it" \
    '[ $rc -eq 1 ] && [ "$out" = "gh-dash: still running after 5 s (pid $stub); kill -9 $stub ends it without telling Greenhouse" ] && cmd_has "$stub" gh-dash' \
    "rc=$rc out=$out"
  kill -9 "$stub" 2>/dev/null; rm -f "$ST/s1/dash.pid" "$ST/s1/dash.port"

  url=$(st_url "$ST/s2")
  no_header=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/api/stop")
  as_get=$(curl -s -o /dev/null -w '%{http_code}' -H 'x-gh-dash: 1' "$url/api/stop")
  rebound=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'x-gh-dash: 1' -H 'Host: rebound.example' "$url/api/stop")
  sleep 0.5
  still=$(curl -s -o /dev/null -w '%{http_code}' "$url/api/state")
  check "POST /api/stop without x-gh-dash gets 403 and the dashboard keeps answering /api/state" \
    '[ "$no_header" = 403 ] && [ "$as_get" = 404 ] && [ "$rebound" = 403 ] && [ "$still" = 200 ] && cmd_has "$b" gh-dash' \
    "no header=$no_header GET=$as_get other Host=$rebound state=$still"

  for _ in $(seq 60); do curl -s "$url/api/state" | grep -q '"state":"reporting"' && break; sleep 0.1; done
  : >"$ST/calls"
  reply=$(curl -s -X POST -H 'x-gh-dash: 1' "$url/api/stop")
  for _ in $(seq 40); do cmd_has "$b" gh-dash || break; sleep 0.1; done
  check "POST /api/stop with the header replies 200, sends a p_stopping report, and exits" \
    '[ "$reply" = "{\"stopping\":true}" ] && ! cmd_has "$b" gh-dash && grep -qx "report_agent_state stopping" "$ST/calls" && [ ! -e "$ST/s2/dash.pid" ]' \
    "reply=$reply calls=$(tr '\n' ' ' <"$ST/calls")"

  # A work chat on TST-30, open in this repo, holding its claim.
  sid=3a3a3a3a-0000-4000-8000-000000000030
  chat=$(bg_pid node "$ST/claude")
  session_file "$chat" "$sid" "$REPO" tst-30
  printf 'since=x\nticket=TST-30\nrole=work\nlabel=TST-30/work\npath=%s\n' "$REPO" >"$ST/s1/chats/$sid"
  mkdir -p "$ST/s1/claims/TST-30" && printf 'label=TST-30/work\npath=%s\nsince=x\nchat=%s\n' "$REPO" "$sid" >"$ST/s1/claims/TST-30/owner"
  st_up "$ST/s1"; c=$st_pid; url=$(st_url "$ST/s1")
  no_header=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "{\"session\":\"$sid\"}" "$url/api/stop-chat")
  check "POST /api/stop-chat without x-gh-dash gets 403" '[ "$no_header" = 403 ] && cmd_has "$chat" claude' "code=$no_header"

  open_state=$(curl -s "$url/api/state"); curl -s "$url/" >"$ST/page.html"   # for page_run below
  before=$(render_card "$url" TST-30)
  reply=$(curl -s -X POST -H 'x-gh-dash: 1' -d "{\"session\":\"$sid\"}" "$url/api/stop-chat")
  after=$(render_card "$url" TST-30)
  check "POST /api/stop-chat ends an open chat in this repo, and its claimed card shows the unclaim line" \
    '[ "$reply" = "{\"stopped\":true}" ] && ! cmd_has "$chat" claude && printf "%s\n%s" "$before" "$after" | node -e '"'"'
      const [b, a] = require("fs").readFileSync(0, "utf8").split("\n").map((l) => JSON.parse(l));
      process.exit(b.open && b.card.includes("aria-label=\"stop tst-30\"") && a.stopped === true && !a.open && !a.card.includes("data-stop")
        && a.card.includes("stopped from gh-dash") && a.card.includes("gh-coord unclaim TST-30 TST-30/work") ? 0 : 1);'"'"'' \
    "reply=$reply before=$before after=$after"

  plain=$(bg_pid sleep 30)
  session_file "$plain" 3a3a3a3a-0000-4000-8000-000000000031 "$REPO" tst-31
  away=$(bg_pid node "$ST/claude")
  session_file "$away" 3a3a3a3a-0000-4000-8000-000000000032 "$ROOT/elsewhere" tst-32
  refused=""
  for s in 3a3a3a3a-0000-4000-8000-000000000031 3a3a3a3a-0000-4000-8000-000000000032 3a3a3a3a-0000-4000-8000-0000000000ff "../$sid"; do
    refused="$refused$(curl -s -w ' %{http_code}' -X POST -H 'x-gh-dash: 1' -d "{\"session\":\"$s\"}" "$url/api/stop-chat");"
  done
  want="{\"error\":\"that chat isn't open in TST\"} 404;"
  check "POST /api/stop-chat refuses a session that isn't open here, and one whose pid isn't a claude process" \
    '[ "$refused" = "$want$want$want$want" ] && cmd_has "$plain" sleep && cmd_has "$away" claude' "$refused"

  stub=$(stubborn claude)
  session_file "$stub" 3a3a3a3a-0000-4000-8000-000000000033 "$REPO" tst-33
  reply=$(curl -s -w ' %{http_code}' -X POST -H 'x-gh-dash: 1' -d '{"session":"3a3a3a3a-0000-4000-8000-000000000033"}' "$url/api/stop-chat")
  check "POST /api/stop-chat answers 409 for a chat still running after 5 s, and never SIGKILLs it" \
    '[ "$reply" = "{\"error\":\"tst-33 is still running after 5 s (pid $stub)\"} 409" ] && cmd_has "$stub" claude' "reply=$reply"
  kill -9 "$stub" 2>/dev/null

  page=$(page_run "$ST/page.html" "$open_state")
  check "the page: a card's octagon arms for 3 s and stays armed (and focused) across a redraw; Esc or arming another disarms it; a second click stops it" \
    '[ "$(echo "$page" | sed -n 1p)" = ok ]' "$page"
  check "the page: Stop asks with the open-chat count and Cancel sends nothing; a failed stop keeps polling; a stop shows the stopped panel and drops the poll in flight" \
    '[ "$(echo "$page" | sed -n 2p)" = ok ]' "$page"

  kill "$a" "$b" "$c" "$st_fake" 2>/dev/null; kill "$plain" "$away" "$chat" 2>/dev/null
  wait "$a" "$b" "$c" "$st_fake" 2>/dev/null
else
  not_ok "gh-dash report payload" "node or gh-dash missing"
fi

echo "1..$n"
[ "$failed" -eq 0 ] || { echo "# $failed of $n failed"; exit 1; }

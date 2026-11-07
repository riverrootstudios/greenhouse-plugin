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
  payload=$(cd "$REPO" && GREENHOUSE_MACHINE=test-box "$DASH" --report-preview 2>/dev/null)
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
  cp "$COORD" "$DASH" "$FAKE/bin/"
  printf '#!/bin/sh\ncase "$1" in agents) echo "[]" ;; --bg) echo "backgrounded · 0123abcd" ;; esac\n' >"$FAKE/path/claude"
  # ps feeds only the page's process list, so each call it logs is a page-only reading.
  printf '#!/bin/sh\necho ps >>"%s"\n' "$FAKE/ps-calls" >"$FAKE/path/ps"
  chmod +x "$FAKE/path/claude" "$FAKE/path/ps"
  node -e '
    const http = require("http"), fs = require("fs");
    let queued = 2;
    http.createServer((req, res) => {
      req.resume();
      req.on("end", () => {
        const fn = req.url.split("/").pop();
        fs.appendFileSync(process.argv[1], fn + "\n");
        const reply = (code, body) => { res.writeHead(code, { "content-type": "application/json" }); res.end(body); };
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
  kill "$dash" "$fake" 2>/dev/null; wait "$dash" "$fake" 2>/dev/null
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
  kill "$nm_dash" 2>/dev/null; wait "$nm_dash" 2>/dev/null
  nm_up
  again=$(nm_start '{"kind":"review"}')
  kill "$nm_dash" 2>/dev/null; wait "$nm_dash" 2>/dev/null
  check "loop chats take the next number, and a ticket chat that doesn't show as open is numbered, not reused" \
    '[ "$names" = "tst-review 1, tst-review 2, tst-7 fix, tst-7 fix 2" ]' "$names $(tr '\n' ' ' <"$NM/dash.log")"
  check "a restarted gh-dash remembers the names it gave out today" '[ "$again" = "tst-review 3" ]' "$again"
else
  not_ok "gh-dash report payload" "node or gh-dash missing"
fi

echo "1..$n"
[ "$failed" -eq 0 ] || { echo "# $failed of $n failed"; exit 1; }

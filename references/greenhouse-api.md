# Greenhouse API Reference

Detailed API access patterns for Greenhouse (Supabase PostgreSQL + PostgREST). Loaded by skills that make direct API calls.

---

## Authentication

Greenhouse uses org-scoped API keys (`ghk_live_*`) that are exchanged for short-lived JWTs. This ensures all data access is scoped to the caller's organization.

### Environment Variables

| Var | Purpose |
|-----|---------|
| `GREENHOUSE_URL` | Supabase project URL (e.g., `https://xxxx.supabase.co`) |
| `GREENHOUSE_PUBLIC_KEY` | Supabase anon key (public, used as `apikey` header) |
| `GREENHOUSE_API_KEY` | Org API key (`ghk_live_*`) — never exposed in logs or committed |

### Session Authentication

Before making API calls, ensure a fresh JWT via the [`gh-jwt`](../bin/gh-jwt) helper:

```bash
eval "$(gh-jwt)"
```

`gh-jwt` exchanges `GREENHOUSE_API_KEY` for a session token, caches it at `~/.greenhouse/jwt` (mode 600), and auto-refreshes within 60s of expiry. Cached calls are network-free, so re-run it freely before any sequence of API calls — this is the mechanism that survives shell-state loss between Bash tool invocations.

If authentication fails (invalid/revoked/expired key), `gh-jwt` emits a shell-eval'able error to stderr and exits non-zero; stop and report.

#### Manual flow (for debugging)

The underlying RPC, in case you need to call it directly:

```bash
curl -s --connect-timeout 5 --max-time 15 --retry 2 -X POST "${GREENHOUSE_URL}/rest/v1/rpc/authenticate_key" \
  -H "apikey: ${GREENHOUSE_PUBLIC_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"p_api_key\": \"${GREENHOUSE_API_KEY}\"}" | jq -r '.token'
```

Token is valid for 1 hour. `gh-jwt` is the preferred entry point — it handles caching and expiry.

### Standard Headers

Every Greenhouse API call after authentication includes these headers:

```
-H "apikey: $GREENHOUSE_PUBLIC_KEY"
-H "Authorization: Bearer $GREENHOUSE_JWT"
-H "Content-Type: application/json"
```

For writes that need the response back, add: `-H "Prefer: return=representation"`

### Standard curl flags

Every Greenhouse `curl` — in any skill, whether or not the example shows them — runs with:

```
--connect-timeout 5 --max-time 15 --retry 2
```

`--retry` only retries transient failures (timeouts, 408/429/5xx), never a 4xx answer. Examples across the skills omit the flags for brevity; add them when you run the call.

---

## URL Construction

- **Tables:** `$GREENHOUSE_URL/rest/v1/{table}?{filters}`
- **RPC functions:** `$GREENHOUSE_URL/rest/v1/rpc/{function_name}`
- **Views:** `$GREENHOUSE_URL/rest/v1/{view_name}?{filters}` (queried like tables)

---

## Operation Mapping

| Operation | Endpoint |
|---|---|
| Create ticket | `POST /rest/v1/rpc/create_ticket` — atomic, returns `{id, display_id, number, title, status, created_at}` |
| Create epic | `POST /rest/v1/epics` with `Prefer: return=representation`; payload must include `"org_id": "${GREENHOUSE_ORG_ID}"` |
| Update ticket | `PATCH /rest/v1/tickets?display_id=eq.{ID}` — always set `updated_by` |
| Update epic | `PATCH /rest/v1/epics?id=eq.{UUID}` — always set `updated_by` |
| Full ticket context | `POST /rest/v1/rpc/get_ticket_context` with `{"p_display_id": "{ID}"}` — returns ticket + epic + relations + last 5 comments (~400 tokens) |
| Light ticket fetch | `GET /rest/v1/tickets?display_id=eq.{ID}&select={fields}` |
| Search tickets | `GET /rest/v1/tickets?{filters}&select={fields}` — use PostgREST operators (eq, in, ilike, fts) |
| Search epics | `GET /rest/v1/epics?{filters}&select={fields}` |
| Create comment | `POST /rest/v1/comments` with `{"ticket_id": "{uuid}", "author": "${GREENHOUSE_TEAM_USERNAME}", "body": "{text}", "org_id": "${GREENHOUSE_ORG_ID}"}` — never hand-roll a JWT decode, see [common-operations §org_id on writes](common-operations.md#org_id-on-writes) |
| Get comments | `GET /rest/v1/comments?ticket_id=eq.{uuid}&select=author,body,created_at&order=created_at.desc&limit={N}` — `get_ticket_context` already carries the latest 5; only call this when you need more |

---

## Token Efficiency

Always specify `select` to limit response fields:

```
# Light ticket list
GET /rest/v1/tickets?project_id=eq.{id}&status=not.in.(harvest,weeded)&select=display_id,title,status,priority,assignee&order=priority.asc

# Full context in one call
POST /rest/v1/rpc/get_ticket_context
{"p_display_id": "RG-42"}
```

---

## UUID Resolution

Many operations require ticket UUIDs. Patterns:

1. **Single ticket context:** `get_ticket_context` returns the UUID in the `id` field
2. **Batch resolution:** `POST /rest/v1/rpc/resolve_display_ids` with `{"p_display_ids": ["RG-15", "RG-8"]}` — returns `[{display_id, id}]`
3. **Project UUID:** read from the `greenhouse` config block in CLAUDE.md (`project_id`)

---

## `updated_by` Rule

Every PATCH to tickets or epics must include `updated_by`. Set to:
- `${GREENHOUSE_TEAM_USERNAME}` (e.g. `"dan"`) for human-initiated skills — attribution is an identity value, so it comes from the token, never from GitHub or the CLAUDE.md Team table (a legacy CLAUDE.md that says otherwise is superseded — see [conventions §Current user resolution](../skills/conventions/SKILL.md#current-user-resolution))
- `"claude"` for autonomous skills like `work-ticket`

`updated_by` carries no RLS predicate of its own, but keeping it on the same source as the identity-bound columns is what stops the two from drifting apart in the data. See [common-operations §identity on writes](common-operations.md#identity-on-writes) for the columns RLS *does* enforce, and [conventions §Current user resolution](../skills/conventions/SKILL.md#current-user-resolution) for the identity/display split.

---

## Error Handling

| HTTP Status | Action |
|-------------|--------|
| 200-204 | Success — continue. A filtered PATCH that matched 0 rows (`[]` with `return=representation`) is also success: the guard said there was nothing to change |
| 400 | Bad input — never resend the same request. Fix the field names/types, then send the corrected request once; if it still fails, report |
| 401/403 (incl. `42501`) | Auth or RLS — don't retry. Re-run `eval "$(gh-jwt)"` once for a 401; report anything else (see [common-operations §identity on writes](common-operations.md#identity-on-writes)) |
| 404 | Not found — report to user |
| 409 | Conflict (e.g. a unique-key race) — wait 1s, retry once; the only 4xx that is retried |
| Other 4xx (`PGRST*`) | Don't retry — report the PostgREST error |
| 500+ | Server error — `--retry 2` already backed off; don't loop further. Queue locally (see Fallback in common-operations.md), continue with git ops |
| Network error / timeout | Queue locally, continue with git ops. A timed-out write may have committed — the queue's guards make replay safe (see [common-operations §Sync Queue Replay](common-operations.md#sync-queue-replay)) |
